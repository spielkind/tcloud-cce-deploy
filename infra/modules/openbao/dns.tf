# =============================================================================
# Public DNS recordset for the OpenBao ELB public IP.
# =============================================================================
resource "opentelekomcloud_dns_recordset_v2" "public" {
  count = var.enable_public_dns_record ? 1 : 0

  zone_id = var.public_dns_zone_id
  name    = "${var.public_dns_record_name}."
  type    = "A"
  ttl     = 300
  records = [opentelekomcloud_vpc_eip_v1.elb.publicip[0].ip_address]
}
