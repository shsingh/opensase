// OpenSASE Kubernetes base manifests, generated from declarative CUE.
//
// Render with:  nix run .#k8s-manifests        (writes k8s/manifests.yaml)
// or directly:  cue export ./k8s --out yaml
//
// The service model below mirrors nix/images.nix (same four images, same
// ports/volumes) so compose, the appliance, and Kubernetes stay aligned;
// issue #10 tracks the full overlay (readiness gates, PKI Secret injection,
// transparent-proxy notes).
package k8s

// Inputs (override with -t at export time, e.g. `-t imageTag=v0.1.0`).
imageRepo: "ghcr.io/shsingh" // @inject string
imageTag:  "latest"          // @inject string

_SVC: [string]: {
	image:                        string
	caps:                         [...string]
	volume:                       string          // RWO PVC mount path, "" = none
	ports: [...{
		name:     string
		port:     int
		protocol: string
	}]
	env: [...{
		name:  string
		value: string
	}]
}

_SVC: openvpn: {
	image:   "opensase-openvpn"
	caps:    ["NET_ADMIN"]
	volume:  "/data-priv" // server.conf + PKI must be injected before start
	ports:   [{name: "vpn", port: 5443, protocol: "UDP"}]
	env:     []
}
_SVC: dnsmasq: {
	image:  "opensase-dnsmasq"
	caps:   []
	volume: "/var/lib/misc"
	ports: [{name: "dns-tcp", port: 53, protocol: "TCP"}, {name: "dns-udp", port: 53, protocol: "UDP"}]
	env:    []
}
_SVC: clamav: {
	image:  "opensase-clamav"
	caps:   []
	volume: "/var/lib/clamav" // signature DB, bootstrap on first start
	ports:  [{name: "clamd", port: 3310, protocol: "TCP"}]
	env:    []
}
_SVC: mitmproxy: {
	image:  "opensase-mitmproxy"
	caps:   []
	volume: "/data" // decision log + confdir
	ports:  [{name: "proxy", port: 8080, protocol: "TCP"}]
	env: [
		{
			name:  "CLAMD_HOST"
			value: "opensase-clamav"
		},
		{
			name:  "CLAMD_PORT"
			value: "3310"
		},
	]
}

_services: [ for k, _ in _SVC {k} ]



_deploymentObjs: {for S in _services {"\(S)": {
	apiVersion: "apps/v1"
	kind:       "Deployment"
	metadata: name: "opensase-\(S)"
	spec: {
		replicas: 1
		selector: matchLabels: app: S
		template: {
			metadata: labels: app: S
			spec: containers: [{
				name:  S
				image: "\(imageRepo)/\(_SVC[S].image):\(imageTag)"
				ports: _SVC[S].ports
				env:   _SVC[S].env
				securityContext: capabilities: add: _SVC[S].caps
				volumeMounts: ([
					for p in [_SVC[S].volume] if p != "" {
						name:   "\(S)-data"
						mountPath: p
					},
				])
			}]
			volumes: ([
				for p in [_SVC[S].volume] if p != "" {
					name:                  "\(S)-data"
					persistentVolumeClaim: claimName: "\(S)-data"
				},
			])
		}
	}
}}}

_serviceObjs: {for S in _services {"\(S)": {
	apiVersion: "v1"
	kind:       "Service"
	metadata: name: "opensase-\(S)"
	spec: {
		selector: app: S
		ports:    _SVC[S].ports
	}
}}}

_pvcObjs: {for S in _services {"\(S)": {
	apiVersion: "v1"
	kind:       "PersistentVolumeClaim"
	metadata: name: "\(S)-data"
	spec: {
		accessModes: ["ReadWriteOnce"]
		resources: requests: storage: "1Gi"
	}
}}}

// Kubernetes List envelope: one doc, natively consumable by `kubectl apply`.
list: {
	apiVersion: "v1"
	kind:       "List"
	items: ([
		for _, v in _pvcObjs {v},
		for _, v in _serviceObjs {v},
		for _, v in _deploymentObjs {v},
	])
}

// Render: nix run .#k8s-manifests (writes k8s/manifests.yaml via
// `cue export ./k8s -e list --out yaml`); override imageTag with
// `-t imageTag=vX.Y.Z`.
