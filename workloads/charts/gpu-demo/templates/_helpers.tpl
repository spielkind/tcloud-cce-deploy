{{/* CPU/RAM resources plus either a whole GPU or an xGPU slice (VRAM in 128 MiB units, compute in percent). */}}
{{- define "gpu-demo.resources" -}}
{{- $r := deepCopy .resources -}}
{{- $limits := default dict $r.limits -}}
{{- if .slicing -}}
{{- $_ := set $limits "volcano.sh/gpu-mem.128Mi" (int (mulf .slice.memGib 8)) -}}
{{- $_ := set $limits "volcano.sh/gpu-core.percentage" (int .slice.corePercent) -}}
{{- else -}}
{{- $_ := set $limits "nvidia.com/gpu" 1 -}}
{{- $requests := default dict $r.requests -}}
{{- $_ := set $requests "nvidia.com/gpu" 1 -}}
{{- $_ := set $r "requests" $requests -}}
{{- end -}}
{{- $_ := set $r "limits" $limits -}}
{{- toYaml $r -}}
{{- end -}}

{{/* Slice identity shown in the GPU slicing tab. */}}
{{- define "gpu-demo.sliceEnv" -}}
- name: SLICE_NAME
  value: {{ .name | quote }}
- name: SLICE_MEM_GIB
  value: {{ .slice.memGib | quote }}
- name: SLICE_CORE_PERCENT
  value: {{ .slice.corePercent | quote }}
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
{{- end -}}

{{/* JSON list of slice workers for the playground. */}}
{{- define "gpu-demo.sliceWorkers" -}}
{{- $out := list -}}
{{- range .Values.slicing.workers -}}
{{- $out = append $out (dict "name" .name "url" (printf "http://gpu-demo-slice-%s:8000" .name) "mem_gib" .memGib "core_percent" .corePercent) -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
