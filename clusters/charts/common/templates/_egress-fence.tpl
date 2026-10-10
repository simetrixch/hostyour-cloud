{{/*
common.publicEgressFence — a NetworkPolicy that lets every pod of the caller's namespace reach DNS
and the public internet, and nothing else. It is for a namespace that runs code this platform does
not vouch for: the gate runs charts a tenant wrote, and the E2E runner's browser loads a tenant's
app. Calico enforces it, and it applies to every pod of the namespace (podSelector: {}).

Everything else is denied by carving two sets of addresses out of the allow-all-egress rule:

  the private and special-use ranges: the cluster LAN, the cluster's own pod and service CIDRs
  (microk8s defaults: pods 10.1.0.0/16, services 10.152.183.0/24, both inside 10.0.0.0/8), and
  cloud metadata (169.254.x);

  global.nodeCidrs: this cluster's own node addresses, which are what a pod reaches the API server
  at, anything with hostNetwork at (the Manager, clusters/inventories/manager/values-common.yaml
  hostNetwork), and the ingress controller's host ports at, and through those every Ingress of
  the cluster.

THE SECOND SET IS NOT INSIDE THE FIRST, and believing it was is what once left the gate's fence
open. A cloud node's own address is a PUBLIC address: on a real onboarding run the sandbox reached
that node's API server on 16443 and the Manager's address. A node's addresses cannot be derived at
render time, so they are stated as a value, and this template REFUSES TO RENDER without them rather
than emitting a boundary that names nothing to deny.

An additional policy may open a pinhole for one pod: NetworkPolicy rules across policies add up.

Call: include "common.publicEgressFence" (dict "root" $ "name" "gate-egress-fence")
*/}}
{{- define "common.publicEgressFence" -}}
{{- $nodeCidrs := .root.Values.global.nodeCidrs | default list -}}
{{- if not $nodeCidrs }}
{{- fail (printf "global.nodeCidrs is empty, so the egress fence %s has no address to deny and its namespace would reach this cluster's API server, its hostNetwork workloads and every Ingress at the node's own address. Write the CIDRs of this cluster's nodes and its API server into clusters/active/<fqdn>.yaml (global.nodeCidrs), which loads last in the app's valueFiles chain; clusters/platform/values-common.yaml states the key and what belongs in it." .name) }}
{{- end }}
{{- range $nodeCidrs }}
{{- if contains ":" . }}
{{- fail (printf "global.nodeCidrs carries the IPv6 range %q, and the egress fence denies it by carving it out of an ipBlock whose cidr is 0.0.0.0/0. Kubernetes refuses an `except` that does not lie inside its own cidr, so this renders a NetworkPolicy the API server rejects, and a rejected fence is no fence while the namespace runs anyway. Write IPv4 ranges only: the fence's rules are all IPv4, and a pod under an egress policy may go nowhere a rule does not name, so IPv6 destinations are already denied whole." .) }}
{{- end }}
{{- end -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    app.kubernetes.io/name: {{ .root.Chart.Name }}
    app.kubernetes.io/managed-by: {{ .root.Release.Service }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  # An empty ingress rule list denies ALL inbound. A Tekton TaskRun pod needs no inbound path
  # (step results travel through files and pod status, logs are collected node-side), and nothing
  # on the platform may address the namespace.
  ingress: []
  egress:
    # (1) kube-dns only, for name resolution. Needed as an explicit selector rule because the
    # kube-dns Service and pod addresses sit inside 10.0.0.0/8, which rule (2) excludes. Calico
    # matches the post-DNAT destination (the coredns POD in kube-system, labelled
    # k8s-app=kube-dns), so this pinhole is DNS only and does NOT re-open the cluster range.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # (2) The public internet ONLY. The except list removes every private and special-use range:
    #   10.0.0.0/8     - cluster LAN, microk8s pod and service CIDRs, every in-cluster service
    #   172.16.0.0/12  - private range (docker bridges etc.)
    #   192.168.0.0/16 - private range (office and home LANs)
    #   100.64.0.0/10  - CGNAT and VPN overlay range
    #   169.254.0.0/16 - link-local, cloud metadata endpoints included
    # and then this cluster's own node addresses. Nothing else may be added here: an entry is a
    # hole the namespace is not allowed to have.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 100.64.0.0/10
              - 169.254.0.0/16
              {{- range $nodeCidrs }}
              - {{ . }}
              {{- end }}
{{- end }}
