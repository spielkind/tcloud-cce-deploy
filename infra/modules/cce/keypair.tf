# Generate an RSA key pair unless a public key is supplied. RSA is used because
# OTC compute key pairs do not accept every key type (e.g. ed25519) everywhere.
resource "tls_private_key" "ssh" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "opentelekomcloud_compute_keypair_v2" "this" {
  name       = "${var.name_prefix}-keypair"
  public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.ssh[0].public_key_openssh
}
