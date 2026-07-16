#!/usr/bin/env zsh
# AWS Client VPN (SAML) — headless connect helpers, sourced by init.zsh.
#
# Connects to an AWS Client VPN profile from the terminal without the GUI, by
# reusing the SAML-patched openvpn binary + exported .ovpn profile that the
# official AWS VPN Client already installed. See bin/aws-vpn-connect and
# ./README.md for the flow.
#
#   vpn-up [profile]   connect (default profile: ariel-ps); browser SSO opens
#   vpn-down           tear the headless tunnel down
#   vpn-status         is a headless tunnel up?
#   awsvpn ...         same, explicit namespaced entrypoint

_AWS_VPN_DIR="${0:A:h}"

awsvpn()     { "$_AWS_VPN_DIR/bin/aws-vpn-connect" "$@"; }
vpn-up()     { "$_AWS_VPN_DIR/bin/aws-vpn-connect" "$@"; }
vpn-down()   { "$_AWS_VPN_DIR/bin/aws-vpn-connect" --down; }
vpn-status() { "$_AWS_VPN_DIR/bin/aws-vpn-connect" --status; }
