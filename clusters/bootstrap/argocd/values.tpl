# ArgoCD Helm Values

# Global Configuration
global:
  domain: argo.<fqdn>

  # WHAT EVERY COMPONENT OF THE RECONCILER TRUSTS.
  #
  # Signing in is not only a browser talking to this server. Once the browser comes back with an
  # authorization code, the argocd-server POD exchanges it for a token by calling
  # https://idp.<fqdn> itself, and it verifies that certificate against its own container's trust
  # store — the public root list its image was built with. On an installation issuing from an
  # authority it minted for itself, that call is refused and what a person sees is `invalid_client`,
  # a message about the client rather than about the trust. This platform has produced that message
  # once already.
  #
  # ON `global` AND NOT ON THE SERVER ALONE: the repository server speaks to forges and chart
  # repositories, and the application controller speaks to every registered cluster — including, on
  # a master, the remote slaves. All of them verify, all of them read the same variable, and naming
  # them one by one would leave the next component to be added out.
  #
  # WHY NOT `oidc.config.rootCA`, which this chart also offers: it holds for the sign-in exchange and
  # for nothing else, so every other outbound call would go on using the image's list. This says what
  # the process trusts rather than configuring one call.
  #
  # The file is a SUPERSET — the public roots are in it in both states of the certificate switch —
  # so this adds an authority and takes none away. See
  # clusters/bootstrap/cert-manager/trust-bundle-public.yaml.
  env:
    - name: SSL_CERT_FILE
      value: /etc/platform-trust/ca-certificates.crt

  extraVolumes:
    - name: platform-trust
      configMap:
        name: platform-trust

  extraVolumeMounts:
    - name: platform-trust
      mountPath: /etc/platform-trust
      readOnly: true

# Server Configuration
server:
  service:
    type: ClusterIP

  # Chart-bundled k8s Ingress disabled — we ship our own Traefik IngressRoute
  # (clusters/bootstrap/argocd/ingressroute.yaml) for consistency with Vault and the
  # IdP. Middlewares + native TLS lives in the IngressRoute spec.
  ingress:
    enabled: false

  # TLS terminated at the IngressRoute → talk plaintext to argocd-server.
  extraArgs:
    - --insecure

# Manager Configuration
controller:
  replicas: 1

# Repo Server Configuration
repoServer:
  replicas: 1

# Redis Configuration
redis:
  enabled: true

# Configs
configs:
  params:
    server.insecure: true
  # Disable the built-in `admin` user — OIDC via Authentik is the sole
  # login path. The `argocd-initial-admin-secret` K8s Secret is left in
  # place so emergency CLI access (`argocd login --username admin
  # --password` with the value out of that Secret) still works on the host, but
  # the web UI's password form is removed and admin can't sign in to it.
  #
  # Recovery if Authentik is unreachable: set `admin.enabled: "true"`
  # here and `helm upgrade` (i.e. re-run --deploy-argocd). Or use the
  # `argocd-cm` ConfigMap directly via kubectl.
  cm:
    admin.enabled: "false"
    url: https://argo.<fqdn>
    # Which Application manages an object is written into the annotation
    # argocd.argoproj.io/tracking-id, and ArgoCD overwrites it on every apply —
    # which is what makes it evidence rather than a claim. Two admission
    # policies decide on it: the build-namespace guard
    # (clusters/inventories/consumer-build/templates/vap-namespace-build-label.yaml) and the
    # per-consumer policy the Manager renders. Stated here rather than left
    # to the version default, because the alternative (`label`) carries the
    # tracking mark in app.kubernetes.io/instance, which any chart may set —
    # both policies would then read a value the unit itself supplies.
    application.resourceTrackingMethod: annotation
    # Custom health check for Ingress on bare-metal (MicroK8s)
    # Default check requires status.loadBalancer.ingress which is never
    # populated without a cloud LoadBalancer. Mark Ingress as Healthy
    # once it has rules assigned by the controller.
    resource.customizations.health.networking.k8s.io_Ingress: |
      hs = {}
      hs.status = "Healthy"
      hs.message = ""
      return hs
    # OIDC client config — Authentik provides the OIDC issuer at
    # idp.<fqdn>. The clientSecret is read from the K8s Secret
    # `argocd-oidc` (key `clientSecret`) which is created in
    # this namespace. ArgoCD's `$secret-name:key` syntax substitutes it
    # at runtime.
    oidc.config: |
      name: Authentik
      issuer: https://idp.<fqdn>/application/o/argocd/
      clientID: argocd
      clientSecret: $argocd-oidc:clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups
      requestedIDTokenClaims:
        groups:
          essential: true
  # Map the platform's own `admins` group to this component's admin role.
  # ONE NAME FOR THE PLATFORM'S STAFF, and these are the four products that
  # admit on it, so no component admits somebody another one refuses:
  # the manager (adminsGroup in clusters/inventories/manager/values-common.yaml,
  # and the group PolicyBinding in clusters/bootstrap/idp/blueprints/
  # 99-manager.yaml), this ArgoCD, a slave's ArgoCD
  # (clusters/slaves/slave/values-common.yaml rbac.policy.csv) and Grafana
  # (role_attribute_path in
  # clusters/inventories/observability/values-common.yaml).
  # The group is created by blueprints/15-group-admins.yaml, the
  # deployment puts the first operator into it with the
  # `authentik_group_membership` step, and anybody later is added to it in the
  # provider.
  # NO OTHER PLACE IN THIS TREE DECIDES ADMISSION ON A GROUP, measured over
  # the whole tree: the blueprints carry exactly one PolicyBinding
  # (99-manager.yaml, entry `manager-admins-binding`), there are only the two
  # `policy.csv` files named above
  # and the three `role_attribute_path` lines, and the only Kubernetes `Group`
  # subject anywhere in the tree is `system:authenticated`, in the three Tekton
  # bindings under clusters/inventories/tekton/templates/.
  rbac:
    policy.csv: |
      g, admins, role:admin
    policy.default: role:readonly
    scopes: '[groups]'