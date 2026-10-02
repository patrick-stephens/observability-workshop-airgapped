# Appliance Syslog

The demo has three source classes: container logs, host logs, and appliance logs.
Container logs are tailed from `/var/log/containers/*.log` by the Fluent Bit DaemonSet.
Host logs are a deliberate future extension and are not collected in this demo.
The simulated appliance sends RFC5424 syslog over TCP to `fluent-bit-syslog.observability.svc.cluster.local:5140`.

Appliance syslog is the hard source because it arrives over the network rather than from a file path visible on each node.
A real external appliance also introduces an exposure and network-policy decision; this demo keeps the listener at ClusterIP for in-cluster traffic only.

One agent is easier to assure than three independent collectors.
There is one ingest chokepoint to demonstrate, one configuration to review, and one lifecycle to manage.
The same Fluent Bit ConfigMap defines the inputs, filters, and Loki outputs, so the policy surface is visible in one place.
All three sources land in the same Loki and can be queried in the same interface.
The `sensor-sim` process is built into the existing demo application image, so the air-gapped bundle still uses one app image, one Fluent Bit chart, and one Fluent Bit version.

The syslog listener uses TCP because a Kubernetes Service can route packets from one TCP connection to one backend for that connection's lifetime.
UDP is not connection-sticky across a Kubernetes Service, so packets from one source can reach different Fluent Bit pods and their order is not preserved.
If a real appliance only speaks UDP, that is a design constraint to name and address, not a problem to hide.

Container records retain the original `kubernetes_namespace_name` label and also expose its bounded value as `namespace`, so both the existing Loki query and the standard namespace selector work.
Structured fields such as `contact`, `bearing`, `range_nm`, and `confidence` stay in each JSON log record.
The Loki index uses only the bounded `job`, `source`, `hostname`, and `app_name` labels; sensor identifiers and contact details are not labels.

For a real deployment, the next source would be host logs through Fluent Bit's systemd input.
That is deliberately omitted here because it requires hostPath mounts for the systemd journal on the DaemonSet.
The syslog Service is currently `ClusterIP`; exposing it outside the cluster would require a reviewed NodePort or LoadBalancer and an explicit network policy.
