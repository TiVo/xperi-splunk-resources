# Ansible alert action params

# Common Parameters
action.aaa_rest.param.hosts = <string>
action.aaa_restart.param.hosts = <string>
action.aaa_reboot.param.hosts = <string>
action.ansible_actions.param.hosts = <string>
* List of hosts to include in ansible inventory

action.aaa_reboot.param.ssmSshKey = <string>
action.aaa_restart.param.ssmSshKey = <string>
action.ansible_actions.param.ssmSshKey = <string>
* SSH key path

#
# AdHoc Action Parameters
#
action.ansible_actions.param.play = <string>
* The play header, in yaml

action.ansible_actions.param.tasks = <string>
* The tasks, in yaml

action.ansible_actions.param.execLocation = <string>
* Local sets the inventory to localhost, and is used for REST based tasks
* Remote sets the inventory to the list of hosts from somewhere and executes tasks on those nodes

#
# REST Actions Parameters
#
action.aaa_rest.param.restUrl = <string>
* URL to call for REST actions

action.aaa_rest.param.restUser = <string>
* Username to use for REST actions

action.aaa_rest.param.restPass = <string>
* Password for REST user

action.aaa_rest.param.httpVerb = <string>
* How to send data to HTTP server (GET, POST, DELETE)

# Restart Actions

action.aaa_restart.param.target = <string>
* systemctl target

action.aaa_restart.param.systemctlAction = <string>
* systemctl action (started, stopped, restarted)
