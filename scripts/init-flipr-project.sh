#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Universal Project Bootstrapper for Flipr Organization Repositories
# Generates:
#  1. Root Jenkinsfile (@Library('ms-jenkins-global-lib') _)
#  2. Optimized multi-stage Dockerfiles for each app
#  3. Standardized Helm charts with Argo Rollouts Canary support
# ==============================================================================

PROJECT_DIR="${1:-.}"
PROJECT_NAME="$(basename "$(cd "${PROJECT_DIR}" && pwd)" | tr '[:upper:]' '[:lower:]')"

echo "=========================================================="
echo " Bootstrapping Flipr CI/CD & Argo Helm Stack for: ${PROJECT_NAME}"
echo " Directory: ${PROJECT_DIR}"
echo "=========================================================="

cd "${PROJECT_DIR}"

# 1. Discover App Folders (or use default folders)
APPS=()
for dir in api web admin frontend backend app question-manager college; do
    if [ -d "$dir" ]; then
        APPS+=("$dir")
    fi
done

if [ ${#APPS[@]} -eq 0 ]; then
    echo "No standard sub-folders found. Using current root directory as app."
    APPS=(".")
fi

echo "Detected Apps: ${APPS[*]}"

# 2. Generate Root Jenkinsfile
echo "--> Generating root Jenkinsfile..."
cat << 'EOF' > Jenkinsfile
@Library('ms-jenkins-global-lib') _

multipleFolderBuild(
    config: [
        domainWith: "subdomain",
        apiPath: "api",
        volumes: [uploads:[]]
    ],
    apps: [
EOF

for app in "${APPS[@]}"; do
    APP_TYPE="nodeJs"
    if [[ "$app" == *"web"* ]] || [[ "$app" == *"admin"* ]] || [[ "$app" == *"frontend"* ]] || [[ "$app" == *"college"* ]] || [[ "$app" == *"question"* ]]; then
        APP_TYPE="reactJs"
    fi

    if [ "$app" = "api" ]; then
        cat << EOF >> Jenkinsfile
        [
            ${APP_TYPE}: [
                path: "${app}",
                node_version: '24',
                volumes: ["uploads:/app/uploads"]
            ]
        ],
EOF
    else
        cat << EOF >> Jenkinsfile
        [
            ${APP_TYPE}: [
                path: "${app}",
                node_version: '24'
            ]
        ],
EOF
    fi
done

# Remove trailing comma and close brackets
sed -i '$ s/,$//' Jenkinsfile 2>/dev/null || true
cat << 'EOF' >> Jenkinsfile
    ]
)
EOF

# 3. Generate Dockerfiles & Helm Charts for each App
for app in "${APPS[@]}"; do
    APP_CLEAN="$(echo "${app}" | tr '/' '-' | tr '.' 'root')"
    APP_DIR="${app}"
    HELM_DIR="${APP_DIR}/helm/${APP_CLEAN}-chart"
    TEMPLATES_DIR="${HELM_DIR}/templates"

    mkdir -p "${TEMPLATES_DIR}"

    # Determine App Type
    APP_TYPE="nodeJs"
    TARGET_PORT=3000
    if [[ "$app" == *"web"* ]] || [[ "$app" == *"admin"* ]] || [[ "$app" == *"frontend"* ]] || [[ "$app" == *"college"* ]] || [[ "$app" == *"question"* ]]; then
        APP_TYPE="reactJs"
        TARGET_PORT=80
    fi

    echo "--> Configuring App: ${APP_CLEAN} (${APP_TYPE})..."

    # A. Dockerfile
    if [ ! -f "${APP_DIR}/Dockerfile" ]; then
        if [ "$APP_TYPE" = "reactJs" ]; then
            cat << 'DOCKER' > "${APP_DIR}/Dockerfile"
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline --no-audit || npm install
COPY . .
RUN if npm run | grep -q "build"; then npm run build; fi

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html 2>/dev/null || COPY --from=builder /app/build /usr/share/nginx/html 2>/dev/null || true
RUN printf 'server {\n  listen 80;\n  location / {\n    root /usr/share/nginx/html;\n    index index.html index.htm;\n    try_files $uri $uri/ /index.html;\n  }\n}\n' > /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
DOCKER
        else
            cat << 'DOCKER' > "${APP_DIR}/Dockerfile"
FROM node:24-alpine AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline --no-audit || npm install
COPY . .
RUN if npm run | grep -q "build"; then npm run build; fi
EXPOSE 3000
CMD ["npm", "start"]
DOCKER
        fi
    fi

    # B. Helm Chart.yaml
    cat << CHART > "${HELM_DIR}/Chart.yaml"
apiVersion: v2
name: ${APP_CLEAN}-chart
description: Standardized Helm chart for ${APP_CLEAN} with Argo Rollouts Canary
type: application
version: 1.0.0
appVersion: "1.0.0"
CHART

    # C. Helm values.yaml
    PVC_ENABLED="false"
    if [ "$app" = "api" ]; then PVC_ENABLED="true"; fi

    cat << VALUES > "${HELM_DIR}/values.yaml"
replicaCount: 3

image:
  repository: docker-registry.registry.svc.cluster.local:5000/${PROJECT_NAME}-${APP_CLEAN}
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
  targetPort: ${TARGET_PORT}

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: ${APP_CLEAN}.${PROJECT_NAME}.flipr.local
      paths:
        - path: /
          pathType: Prefix

rollout:
  canary:
    steps:
      - setWeight: 20
      - pause: { duration: 30s }
      - setWeight: 50
      - pause: { duration: 30s }
      - setWeight: 100

persistence:
  enabled: ${PVC_ENABLED}
  storageClass: "longhorn"
  size: 5Gi
  mountPath: /app/uploads
VALUES

    # D. Helm _helpers.tpl
    cat << 'HELPERS' > "${TEMPLATES_DIR}/_helpers.tpl"
{{/* Expand chart name */}}
{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels */}}
{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
HELPERS

    # E. Helm rollout.yaml (Argo Rollout Canary CRD)
    cat << 'ROLLOUT' > "${TEMPLATES_DIR}/rollout.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.service.targetPort }}
          name: http
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        {{- if .Values.persistence.enabled }}
        volumeMounts:
        - name: uploads-storage
          mountPath: {{ .Values.persistence.mountPath }}
        {{- end }}
      {{- if .Values.persistence.enabled }}
      volumes:
      - name: uploads-storage
        persistentVolumeClaim:
          claimName: {{ .Release.Name }}-pvc
      {{- end }}
  strategy:
    canary:
      canaryService: {{ .Release.Name }}-canary
      stableService: {{ .Release.Name }}-stable
      trafficRouting:
        nginx:
          stableIngress: {{ .Release.Name }}-ingress
      steps:
        {{- toYaml .Values.rollout.canary.steps | nindent 8 }}
ROLLOUT

    # F. Helm service.yaml (Stable and Canary Services)
    cat << 'SERVICE' > "${TEMPLATES_DIR}/service.yaml"
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-stable
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
    protocol: TCP
    name: http
  selector:
    app: {{ .Release.Name }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-canary
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
    protocol: TCP
    name: http
  selector:
    app: {{ .Release.Name }}
SERVICE

    # G. Helm ingress.yaml
    cat << 'INGRESS' > "${TEMPLATES_DIR}/ingress.yaml"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}-ingress
  namespace: {{ .Release.Namespace }}
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
  {{- range .Values.ingress.hosts }}
  - host: {{ .host }}
    http:
      paths:
      {{- range .paths }}
      - path: {{ .path }}
        pathType: {{ .pathType }}
        backend:
          service:
            name: {{ $.Release.Name }}-stable
            port:
              number: {{ $.Values.service.port }}
      {{- end }}
  {{- end }}
INGRESS

    # H. Helm pvc.yaml
    if [ "$app" = "api" ]; then
        cat << 'PVC' > "${TEMPLATES_DIR}/pvc.yaml"
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Release.Name }}-pvc
  namespace: {{ .Release.Namespace }}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .Values.persistence.storageClass }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
PVC
    fi
done

echo "=========================================================="
echo " Project Bootstrap Complete for: ${PROJECT_NAME}"
echo "=========================================================="
