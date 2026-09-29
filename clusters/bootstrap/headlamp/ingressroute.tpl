# IngressRoute for Headlamp. Its certificate is the base layer's one,
# served by the TLSStore bootstrap/ingress/certificate.yaml puts in Traefik's own namespace.
#
# BEHIND THE IDENTITY PROVIDER'S FORWARD-AUTH, and Headlamp's own OIDC login after it
# (hostyour-cloud#264). Headlamp answers /config before its login: the name and the tailnet API
# address of every cluster. The middleware idp/forwardauth answers that request with a redirect
# to the identity provider unless the browser holds a session; its provider runs in forward_domain
# mode with the cookie on the whole domain (idp/blueprints/99-proxy-tekton.yaml), so one sign-in
# carries here and Headlamp's own login completes without a second prompt.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
  # THE ADDRESS STAYS kube.<fqdn> WHILE THE NAMESPACE BECOMES headlamp: what a component is
  # called and what a browser types are two different names. The identity provider registers
  # this product at https://kube.<fqdn>/oidc-callback (blueprints/99-headlamp.yaml), so moving
  # the host would take the login with it and cost a certificate for nothing.
  namespace: headlamp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`kube.<fqdn>`)
      kind: Rule
      middlewares:
        - name: forwardauth
          namespace: idp
      services:
        - name: headlamp
          port: 80
  tls:
    store:
      name: default
      namespace: vault
