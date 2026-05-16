{{- define "barman.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "barman.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "barman.labels" -}}
app.kubernetes.io/name: {{ include "barman.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: barman
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "barman.selectorLabels" -}}
app.kubernetes.io/name: {{ include "barman.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "barman.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "barman.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nome do Secret de credenciais (existingSecret ou o renderizado). */}}
{{- define "barman.secretName" -}}
{{- if .Values.credentials.existingSecret -}}
{{- .Values.credentials.existingSecret -}}
{{- else -}}
{{- include "barman.fullname" . -}}-credentials
{{- end -}}
{{- end -}}

{{/* URL de destino S3: s3://<bucket>/<prefix> */}}
{{- define "barman.s3dest" -}}
{{- printf "s3://%s/%s" (required "objectStore.bucket é obrigatório" .Values.objectStore.bucket) (default "barman" .Values.objectStore.prefix) -}}
{{- end -}}

{{/* Bloco de env comum a todos os workloads barman. */}}
{{- define "barman.env" -}}
- name: PGHOST
  value: {{ .Values.postgres.host | quote }}
- name: PGPORT
  value: {{ .Values.postgres.port | quote }}
- name: PGUSER
  value: {{ .Values.postgres.user | quote }}
- name: PGDATABASE
  value: {{ .Values.postgres.database | quote }}
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "barman.secretName" . }}
      key: PGPASSWORD
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "barman.secretName" . }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "barman.secretName" . }}
      key: AWS_SECRET_ACCESS_KEY
- name: AWS_DEFAULT_REGION
  value: {{ .Values.objectStore.region | quote }}
- name: S3_ENDPOINT
  value: {{ required "objectStore.endpoint é obrigatório" .Values.objectStore.endpoint | quote }}
- name: S3_PROVIDER
  value: {{ .Values.objectStore.provider | quote }}
- name: S3_DEST
  value: {{ include "barman.s3dest" . | quote }}
- name: SERVER_NAME
  value: {{ .Values.server.name | quote }}
- name: SLOT
  value: {{ .Values.server.slot | quote }}
- name: COMPRESSION
  value: {{ .Values.backup.compression | quote }}
- name: SPOOL_DIR
  value: /spool
- name: SHIP_INTERVAL
  value: {{ .Values.walArchive.shipIntervalSeconds | quote }}
- name: RETENTION
  value: {{ .Values.retention.policy | quote }}
- name: JOBS
  value: {{ .Values.backup.jobsConcurrency | quote }}
{{- end -}}
