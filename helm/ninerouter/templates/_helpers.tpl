{{/*
Expand the name of the chart.
*/}}
{{- define "ninerouter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Truncated at 63 chars because some Kubernetes name
fields are limited to that.
*/}}
{{- define "ninerouter.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "ninerouter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "ninerouter.labels" -}}
helm.sh/chart: {{ include "ninerouter.chart" . }}
{{ include "ninerouter.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "ninerouter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ninerouter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-component labels. Selectors must stay stable across upgrades, so they carry
only the identity keys — a StatefulSet's selector is immutable.
*/}}
{{- define "ninerouter.ninerouter.selectorLabels" -}}
{{ include "ninerouter.selectorLabels" . }}
app.kubernetes.io/component: ninerouter
{{- end }}

{{- define "ninerouter.headroom.selectorLabels" -}}
{{ include "ninerouter.selectorLabels" . }}
app.kubernetes.io/component: headroom
{{- end }}

{{- define "ninerouter.ninerouter.labels" -}}
{{ include "ninerouter.labels" . }}
app.kubernetes.io/component: ninerouter
{{- end }}

{{- define "ninerouter.headroom.labels" -}}
{{ include "ninerouter.labels" . }}
app.kubernetes.io/component: headroom
{{- end }}

{{- define "ninerouter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ninerouter.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resource names. Kept in helpers so the Service names, the StatefulSet's
serviceName and HEADROOM_URL cannot drift apart.
*/}}
{{- define "ninerouter.headless.name" -}}
{{- printf "%s-headless" (include "ninerouter.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ninerouter.headroom.name" -}}
{{- printf "%s-headroom" (include "ninerouter.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Persistence. The PVC the pod mounts in manual mode, and the cluster-scoped PV
backing it — namespaced in the name because PVs are not namespaced and two
releases in different namespaces would otherwise collide.
*/}}
{{- define "ninerouter.pvcName" -}}
{{- if eq .Values.ninerouter.persistence.mode "existing" }}
{{- .Values.ninerouter.persistence.existingClaim }}
{{- else }}
{{- printf "%s-data" (include "ninerouter.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "ninerouter.pvName" -}}
{{- printf "%s-%s-data" .Release.Namespace (include "ninerouter.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ninerouter.secretName" -}}
{{- if .Values.auth.existingSecret }}
{{- .Values.auth.existingSecret }}
{{- else }}
{{- printf "%s-auth" (include "ninerouter.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Whether the chart's shipped sample secrets are still in place. These values are
committed to git, so anyone can read them; NOTES.txt warns while any is in use.
Returns a non-empty string when at least one sample survives.
*/}}
{{- define "ninerouter.usingSampleSecrets" -}}
{{- if not .Values.auth.existingSecret }}
{{- $samples := list
  "sample-only-replace-me-1111111111111111111111111111111111111111"
  "changeme"
  "sample-only-replace-me-2222222222222222222222222222222222222222"
  "sample-only-replace-me-3333"
}}
{{- range list .Values.auth.jwtSecret .Values.auth.initialPassword .Values.auth.apiKeySecret .Values.auth.machineIdSalt }}
{{- if has . $samples }}yes{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Guards. Rendering fails early with an explanation rather than producing a
manifest the cluster would reject or that would silently lose data.
*/}}
{{- define "ninerouter.validate" -}}
{{/*
Every Service in this chart is named after the fullname, and Service names are
RFC 1035 labels: they must start with a LETTER. The fullname is built from the
release name, so `helm install 9router ...` produces "9router-ninerouter" and
the API server rejects it. Caught here so the failure names the fix instead of
surfacing as a validation error at apply time.
*/}}
{{- $fullname := include "ninerouter.fullname" . }}
{{- if not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $fullname) }}
{{- fail (printf "Resource name %q cannot be used: Kubernetes validates Service names as RFC 1035 labels, which must start with a lower-case letter and contain only letters, digits and '-'. This name comes from the release name %q combined with the chart name. Fix it either way: install under a release name that starts with a letter (helm install ninerouter ... / helmfile release name: ninerouter), or keep the release name and set fullnameOverride, e.g. --set fullnameOverride=ninerouter." $fullname .Release.Name) }}
{{- end }}
{{- if gt (int .Values.ninerouter.replicaCount) 1 }}
{{- fail "ninerouter.replicaCount must be 1: 9Router keeps its state in a SQLite database on a ReadWriteOnce volume, so each replica would get its own independent database rather than sharing one." }}
{{- end }}
{{- if not .Values.auth.existingSecret }}
{{- if or (empty .Values.auth.jwtSecret) (empty .Values.auth.initialPassword) }}
{{- fail "auth.jwtSecret and auth.initialPassword are required, or set auth.existingSecret to the name of a Secret holding JWT_SECRET, INITIAL_PASSWORD, API_KEY_SECRET and MACHINE_ID_SALT. The chart will not generate a signing key, because a generated one would rotate on every upgrade and invalidate every session." }}
{{- end }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.config.authCookieSecure) }}
{{- range .Values.ingress.tls }}
{{- fail "ingress.tls is configured but config.authCookieSecure is false: the auth cookie would be sent without the Secure attribute over an HTTPS site. Set config.authCookieSecure=true." }}
{{- end }}
{{- end }}
{{- if .Values.ninerouter.persistence.enabled }}
{{- $p := .Values.ninerouter.persistence }}
{{- if not (has $p.mode (list "dynamic" "manual" "existing")) }}
{{- fail (printf "ninerouter.persistence.mode must be one of dynamic, manual or existing (got %q)." $p.mode) }}
{{- end }}
{{- if eq $p.mode "existing" }}
{{- if not $p.existingClaim }}
{{- fail "ninerouter.persistence.mode is \"existing\" but persistence.existingClaim is empty. Set it to the name of a PersistentVolumeClaim in this namespace." }}
{{- end }}
{{- end }}
{{- if eq $p.mode "manual" }}
{{- if not $p.manual.path }}
{{- fail "ninerouter.persistence.mode is \"manual\" but persistence.manual.path is empty. Set it to the directory on the node where the database should live, e.g. /mnt/data/ninerouter." }}
{{- end }}
{{- if not (hasPrefix "/" $p.manual.path) }}
{{- fail (printf "ninerouter.persistence.manual.path must be an absolute path (got %q)." $p.manual.path) }}
{{- end }}
{{- if not (has $p.manual.type (list "local" "hostPath")) }}
{{- fail (printf "ninerouter.persistence.manual.type must be \"local\" or \"hostPath\" (got %q)." $p.manual.type) }}
{{- end }}
{{- if and (eq $p.manual.type "local") $p.manual.createPV }}
{{- if and (not $p.manual.nodeName) (not $p.manual.nodeAffinity) }}
{{- fail "A local PersistentVolume requires node affinity — the API server rejects one without it, because the data exists on exactly one node's disk. Set persistence.manual.nodeName to that node, or supply persistence.manual.nodeAffinity." }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Non-secret environment shared by the 9Router container. Empty values are
dropped, because to the application an empty string is not the same as an
unset variable.
*/}}
{{- define "ninerouter.env" -}}
{{- $env := dict
  "DATA_DIR" "/app/data"
  "PORT" (.Values.ninerouter.containerPort | toString)
  "HOSTNAME" "0.0.0.0"
  "NODE_ENV" .Values.config.nodeEnv
  "ENABLE_REQUEST_LOGS" (.Values.config.enableRequestLogs | toString)
  "OBSERVABILITY_ENABLED" (.Values.config.observabilityEnabled | toString)
  "AUTH_COOKIE_SECURE" (.Values.config.authCookieSecure | toString)
  "REQUIRE_API_KEY" (.Values.config.requireApiKey | toString)
  "BASE_URL" .Values.config.baseUrl
  "CLOUD_URL" .Values.config.cloudUrl
  "NEXT_PUBLIC_BASE_URL" (default .Values.config.baseUrl .Values.config.publicBaseUrl)
  "NEXT_PUBLIC_CLOUD_URL" (default .Values.config.cloudUrl .Values.config.publicCloudUrl)
  "HTTP_PROXY" .Values.config.httpProxy
  "HTTPS_PROXY" .Values.config.httpsProxy
  "ALL_PROXY" .Values.config.allProxy
  "NO_PROXY" .Values.config.noProxy
  "SEARXNG_URL" .Values.config.searxngUrl
}}
{{- if .Values.headroom.enabled }}
{{- $_ := set $env "HEADROOM_URL" (printf "http://%s:%d" (include "ninerouter.headroom.name" .) (int .Values.headroom.service.port)) }}
{{- end }}
{{- range $k, $v := .Values.extraEnv }}
{{- $_ := set $env $k ($v | toString) }}
{{- end }}
{{- range $k, $v := $env }}
{{- if $v }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end }}
