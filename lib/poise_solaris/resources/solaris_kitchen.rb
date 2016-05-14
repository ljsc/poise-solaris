#
# Copyright 2016, Noah Kantrowitz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'resolv'
require 'shellwords'

require 'chef/resource'
require 'poise'


module PoiseSolaris
  module Resources
    # (see SolarisKitchen::Resource)
    # @since 1.0.0
    module SolarisKitchen
      # A `solaris_kitchen` resource to set up required infrastructure for
      #  kitchen-zone.
      #
      # @provides solaris_kitchen
      # @action create
      # @example
      #   solaris_kitchen 'kitchen'
      class Resource < Chef::Resource
        include Poise
        provides(:solaris_kitchen)
        actions(:create)
      end

      # Provider for `solaris_kitchen`.
      #
      # @since 1.0.0
      # @see Resource
      # @provides solaris_kitchen
      class Provider < Chef::Provider
        include Poise
        provides(:solaris_kitchen)

        # `create` action for `solaris_kitchen`. Do the needful.
        #
        # @return [void]
        def action_create
          notifying_block do
            create_network
            configure_nat
            configure_dhcpd
            create_template_zone
          end
        end

        private

        def create_network
          execute 'dladm create-etherstub stub0' do
            not_if 'dladm show-etherstub stub0'
          end

          execute 'dladm create-vnic -l stub0 vnic0' do
            not_if 'dladm show-link vnic0'
          end

          execute 'ipadm create-ip vnic0 && ipadm create-addr -T static -a 192.168.0.1/24 vnic0/v4' do
            not_if 'ipadm show-addr vnic0'
          end
        end

        def configure_nat
          file '/etc/ipf/ipnat.conf' do
            content "map net0 192.168.0.0/24 -> 0/32 portmap tcp/udp auto\n"
          end

          # Non-idempotent from Chef's PoV but should be fine.
          execute 'ipadm set-prop -p forwarding=on ipv4'

          service 'svc:/network/ipfilter:default' do
            action :enable
          end
        end

        def configure_dhcpd
          file '/etc/inet/dhcpd4.conf' do
            content <<-EOH
option domain-name "#{node['domain'] || 'local'}";
option domain-name-servers #{Resolv::DNS::Config.new.lazy_initialize.nameserver_port.map {|s| s[0] }.join(' ')};

default-lease-time 86400;

max-lease-time -1;

log-facility local7;

subnet 192.168.0.0 netmask 255.255.255.0 {
    range 192.168.0.100 192.168.0.120;
    option routers 192.168.0.1;
    option broadcast-address 192.168.0.255;
}
EOH
          end

          smf_property 'svc:/network/dhcp/server:ipv4#config/listen_ifnames' do
            value 'vnic0'
          end

          service 'svc:/network/dhcp/server:ipv4' do
            action :enable
          end
        end

        def create_template_zone
          file '/root/template.profile' do
            content <<-EOH
create -b
set brand=solaris
set zonepath=/zones/template
set autoboot=false
set autoshutdown=shutdown
set ip-type=exclusive
add anet
set linkname=net0
set lower-link=stub0
set configure-allowed-address=true
set link-protection=mac-nospoof
set mac-address=auto
end
EOH
          end

          file '/root/template.xml' do
            content <<-EOH
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<!-- Auto-generated by sysconfig -->
<service_bundle type="profile" name="sysconfig">
  <service version="1" type="service" name="system/identity">
    <instance enabled="true" name="node">
      <property_group type="application" name="config">
        <propval type="astring" name="nodename" value="template"/>
      </property_group>
    </instance>
  </service>
  <service version="1" type="service" name="network/physical">
    <instance enabled="true" name="default">
      <property_group type="application" name="netcfg">
        <propval type="astring" name="active_ncp" value="Automatic"/>
      </property_group>
    </instance>
  </service>
  <service version="1" type="service" name="system/name-service/switch">
    <property_group type="application" name="config">
      <propval type="astring" name="default" value="files"/>
    </property_group>
    <instance enabled="true" name="default"/>
  </service>
  <service version="1" type="service" name="system/name-service/cache">
    <instance enabled="true" name="default"/>
  </service>
  <service version="1" type="service" name="system/environment">
    <instance enabled="true" name="init">
      <property_group type="application" name="environment">
        <propval type="astring" name="LANG" value="en_US.UTF-8"/>
      </property_group>
    </instance>
  </service>
  <service version="1" type="service" name="system/timezone">
    <instance enabled="true" name="default">
      <property_group type="application" name="timezone">
        <propval type="astring" name="localtime" value="UTC"/>
      </property_group>
    </instance>
  </service>
  <service version="1" type="service" name="system/config-user">
    <instance enabled="true" name="default">
      <property_group type="application" name="root_account">
        <propval type="astring" name="type" value="role"/>
        <propval type="astring" name="login" value="root"/>
        <propval type="astring" name="password" value=""/>
      </property_group>
    </instance>
  </service>
</service_bundle>
EOH
          end

          execute 'zonecfg -z template -f /root/template.profile && zoneadm -z template install -c /root/template.xml' do
            live_stream true
            not_if { ::File.exist?('/zones/template') }
          end
        end

      end

    end
  end
end