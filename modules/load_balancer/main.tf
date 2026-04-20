# ============================================================
# modules/load_balancer/main.tf — Global HTTP(S) Load Balancer for GKE
# ============================================================
#
# Architecture
# ─────────────────────────────────────────────────────────────
#
#  Internet (port 80)
#      │
#      ▼
#  google_compute_global_forwarding_rule   ← static external IP (anycast)
#      │
#      ▼
#  google_compute_target_http_proxy        ← terminates HTTP, routes via URL map
#      │
#      ▼
#  google_compute_url_map                  ← routing rules (all → default backend)
#      │
#      ▼
#  google_compute_backend_service          ← load balances across instance groups
#      │    │
#      │    └── google_compute_health_check  ← HTTP probe on var.node_port
#      │
#      ├── zone-a GKE instance group  ┐
#      ├── zone-b GKE instance group  ├─ google_compute_instance_group_named_port
#      └── zone-c GKE instance group  ┘  (adds "http"→node_port to each group)
#
#  Firewall (google_compute_firewall.allow_lb_health_checks)
#      └── allows GCP health-checker IPs → gke-node on node_port
#
# ─────────────────────────────────────────────────────────────
# How traffic reaches your app after terraform apply:
#
#   1. Deploy a Kubernetes Service of type NodePort on port var.node_port.
#   2. GCP health checks probe each node on that port. Once healthy,
#      the LB starts forwarding real traffic there.
#   3. kube-proxy on the node forwards the packet to the correct pod.
#
# Why a Global (anycast) LB?
#   Google's anycast network routes each user to the nearest POP,
#   reducing latency worldwide. A regional LB only has one frontend IP.

# ---------------------------------------------------------------
# Named ports on GKE instance groups
# ---------------------------------------------------------------
# A GCP backend service routes HTTP traffic to a *named port* on
# the instance group — it doesn't accept a raw port number directly.
#
# GKE manages its node-pool instance groups but does NOT manage named
# ports, so we can safely add them here without conflicting with GKE.
#
# for_each iterates over each zonal instance group URL that the GKE
# node pool creates (one per zone in a regional cluster).
# toset() de-duplicates and converts the list to a set (required for for_each).
resource "google_compute_instance_group_named_port" "http" {
  for_each = var.instance_group_urls

  zone  = each.key   # zone name is the map key (e.g. "us-central1-a")
  group = each.value # full self-link URL of the instance group
  name  = "http"     # arbitrary label; must match port_name in backend_service
  port  = var.node_port
}

# ---------------------------------------------------------------
# Health check
# ---------------------------------------------------------------
# GCP's health checker sends HTTP GET requests to each node on node_port.
# Only nodes that return a 200 response receive real traffic.
# If you haven't deployed a Service yet, all nodes fail the check and
# the LB returns a 502 — that's expected until you deploy your app.
resource "google_compute_health_check" "http" {
  name               = "${var.name_prefix}-hc"
  check_interval_sec = 10  # probe every 10 s
  timeout_sec        = 5   # wait up to 5 s for a response
  healthy_threshold  = 2   # 2 consecutive successes → healthy
  unhealthy_threshold = 3  # 3 consecutive failures  → unhealthy

  http_health_check {
    port         = var.node_port       # probe this port on each node
    request_path = var.health_check_path # default "/healthz" — set to your app's path
  }
}

# ---------------------------------------------------------------
# Backend service
# ---------------------------------------------------------------
# The backend service glues health checks, load-balancing policy, and
# instance groups together. It is the logical "server farm" the LB routes to.
#
# protocol  = "HTTP" — the LB speaks HTTP to the backends (the nodes).
# port_name = "http" — must match the named port created above.
# load_balancing_scheme = "EXTERNAL" — internet-facing LB.
resource "google_compute_backend_service" "default" {
  name                  = "${var.name_prefix}-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.http.id]

  # Create one backend block per GKE instance group (one per zone).
  # dynamic blocks let us loop over a list and emit repeated config.
  dynamic "backend" {
    for_each = var.instance_group_urls
    content {
      group = backend.value

      # UTILIZATION mode scales based on CPU utilisation of the nodes.
      # The alternative is RATE (requests per second) — use that for
      # request-based autoscaling.
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1.0 # 100 % of capacity is usable
    }
  }

  # Ensure named ports exist before the backend service references them.
  depends_on = [google_compute_instance_group_named_port.http]
}

# ---------------------------------------------------------------
# URL map
# ---------------------------------------------------------------
# A URL map defines routing rules: which backend handles which request path.
# This one routes everything (*) to the single backend service above.
# Later you can add path_matcher blocks to route /api → one service,
# /static → another, etc.
resource "google_compute_url_map" "default" {
  name            = "${var.name_prefix}-url-map"
  default_service = google_compute_backend_service.default.id
}

# ---------------------------------------------------------------
# HTTP proxy
# ---------------------------------------------------------------
# The target HTTP proxy sits between the forwarding rule and the URL map.
# It terminates the HTTP connection and decides which URL map to consult.
# For HTTPS you'd use google_compute_ssl_certificate +
# google_compute_target_https_proxy instead.
resource "google_compute_target_http_proxy" "default" {
  name    = "${var.name_prefix}-http-proxy"
  url_map = google_compute_url_map.default.id
}

# ---------------------------------------------------------------
# Static external IP address
# ---------------------------------------------------------------
# A global address gives you a permanent, anycast IP that you can point
# a DNS A record at. Without this the LB gets an ephemeral IP that
# changes if the forwarding rule is recreated.
resource "google_compute_global_address" "lb_ip" {
  name        = "${var.name_prefix}-lb-ip"
  description = "Static external IP for the GKE load balancer"
}

# ---------------------------------------------------------------
# Forwarding rule
# ---------------------------------------------------------------
# The forwarding rule is the actual "listener" — it receives packets on
# the external IP + port and hands them to the HTTP proxy.
# global forwarding rules (vs regional) work with global anycast addresses.
resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name_prefix}-http-fwd"
  ip_address            = google_compute_global_address.lb_ip.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  load_balancing_scheme = "EXTERNAL"
}

# ---------------------------------------------------------------
# Firewall — allow GCP health checker IPs to reach nodes
# ---------------------------------------------------------------
# GCP runs health checks from two fixed IP ranges. These checks must
# be able to reach your GKE nodes on node_port, or all backends will
# stay "unhealthy" and the LB will return 502 for every request.
#
# 130.211.0.0/22 and 35.191.0.0/16 are Google's documented
# health-checker source ranges. They never change.
#
# We also allow these ranges for real LB traffic because once the GCP
# LB decides to route a packet to a backend, the packet arrives from
# these same source ranges.
resource "google_compute_firewall" "allow_lb_health_checks" {
  name    = "${var.name_prefix}-allow-lb-hc"
  network = var.vpc_name # short name of the VPC (from vpc module output)

  direction = "INGRESS"
  priority  = 900 # higher priority than the default 1000 rules

  allow {
    protocol = "tcp"
    ports    = [tostring(var.node_port)]
  }

  # GCP health-checker and LB traffic source ranges (static, never change).
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  # Only GKE nodes need to receive this traffic.
  target_tags = ["gke-node"]

  description = "Allow GCP LB health checks and traffic to reach GKE nodes on node_port"
}
