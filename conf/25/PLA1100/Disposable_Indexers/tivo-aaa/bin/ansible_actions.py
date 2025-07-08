#!/usr/bin/env python3

import sys, json, argparse

sys.path.insert(0, "./ansible_actions_dependencies")
import ansible_runner, yaml

import logging, logging.handlers

DATEFORMAT = '%m-%d-%Y %H:%M:%S'
LOGFORMAT = '%(asctime)s.%(msecs)03d [%(process)s] %(levelname)s: %(message)s'
formatter = logging.Formatter(LOGFORMAT, datefmt=DATEFORMAT)

FILENAME = '/opt/splunk/var/log/splunk/ansible_actions.log'
fileHandler = logging.handlers.RotatingFileHandler(FILENAME, maxBytes=16*1024*1024, backupCount=5)
fileHandler.setFormatter(formatter)

stderrHandler = logging.StreamHandler(sys.stderr)
stderrHandler.setFormatter(formatter)

logger = logging.getLogger("aaa")
logger.setLevel(logging.INFO)
logger.addHandler(fileHandler)
logger.addHandler(stderrHandler)

def log(msg, level=logging.INFO):
    logger.log(level, msg)
    levelstr = logging.getLevelName(level)

def logEvent(_e, level=logging.INFO):
    e = _e.copy()
    # Remove this very verbose element before logging...
    if 'event_data' in e:
        if 'res' in e['event_data']:
            if 'ansible_facts' in e['event_data']['res']:
                del e['event_data']['res']['ansible_facts']
    log(json.dumps(e), level)


###
# Get SSH keys from SSM
###
def getSshKey(configuration):
    log(f"Looking for SSM SSH Key: {configuration['ssmSshKey']}")

    playbook = {'hosts': 'single','gather_facts': False,'connection':'local','tasks':None}
    tasks = '''
 - name: "go go gadget ssm"
   set_fact:
     sshKey: "{{ lookup('aws_ssm', 'ZAP', decrypt=true, region='us-west-2') }}"
'''

    tasks = tasks.replace("ZAP", configuration['ssmSshKey'])

    parsedTasks = yaml.safe_load(tasks)
    playbook["tasks"] = parsedTasks

    log(f"SSH Playbook :: {json.dumps(playbook)}", logging.DEBUG)

    ar_resp = ansible_runner.interface.run(playbook=[playbook],
                                           inventory="[single]\nlocalhost",
                                           json_mode=True, quiet=True)
    for event in ar_resp.events:
        log(json.dumps(event), logging.DEBUG)
        if event['event'] == "runner_on_ok":
            try:
                sshKey = event['event_data']['res']['ansible_facts']['sshKey']
            except:
                sshKey = None
    
    return sshKey+"\n"

###
# Run REST actions from host managing the alert
###
def runRestTask(configuration):
    log(f"Running REST task against {configuration['restUrl']}")
    retCode = 0
    restBaseTask = f"""- name: "AAA REST"
  uri: 
    timeout: 60
    url: {configuration['restUrl']}
    validate_certs: false
  with_items:
"""
    playbook = {'hosts': 'a','gather_facts': False,'connection':'local','tasks':None}
    parsedTask = yaml.safe_load(restBaseTask)
    parsedTask[0]['with_items'] = configuration['hosts'].split(',')
    parsedTask[0]['uri']['url_username'] = configuration.get('restUser')
    parsedTask[0]['uri']['url_password'] = configuration.get('restPass')
    parsedTask[0]['uri']['method'] = configuration.get('httpVerb',"GET")
    playbook['tasks'] = parsedTask
    log(f"ParsedTask: {parsedTask}")
    log(f"Hosts involved: {parsedTask[0]['with_items']}")
    log(f"Playbook :: {json.dumps(playbook)}")

    ar_resp = ansible_runner.interface.run(playbook=[playbook],
                                           inventory="[a]\nlocalhost",
                                           json_mode=True, quiet=True, timeout=90)
    for event in ar_resp.events:
        log(json.dumps(event), logging.DEBUG)
        if event['event'].startswith('runner_on'):
            logEvent(event)
        if event['event'] == "runner_on_failed":
            retCode = 1
    log(f"Stats: {json.dumps(ar_resp.stats)}")

    return retCode

###
# Run RESTART (or any systemctl) actions -- ssh'ing into the target host(s)
###
def runRestartTask(configuration):
    log("Running RESTART task")
    retCode = 0 
    sshKey = getSshKey(configuration)

    restartBaseTask = f"""- name: "AAA RESTART"
  systemd: 
    name: {configuration['target']}
    state: {configuration['systemctlAction']}
    no_block: yes
  become: yes
  become_user: root
"""
    playbook = {'hosts': 'a','tasks':None}
    parsedTask = yaml.safe_load(restartBaseTask)
    playbook['tasks'] = parsedTask

    log(json.dumps(playbook), logging.DEBUG)

    hosts = configuration['hosts'].replace(',',"\n")

    log(hosts, logging.DEBUG)

    ar_resp = ansible_runner.interface.run(playbook=[playbook],
                                           inventory=f"[a]\n{hosts}",
                                           json_mode=True, ssh_key=sshKey,
                                           quiet=True, timeout=90)
    for event in ar_resp.events:
        log(json.dumps(event), logging.DEBUG)
        if event['event'].startswith('runner_on'):
            logEvent(event)
        if event['event'] == "runner_on_failed":
            retCode = 1
    log(f"Stats: {json.dumps(ar_resp.stats)}")

    return retCode
    


###
# REBOOT -- ssh'ing into the target host(s)
###
def runRebootTask(configuration):

    log("Running REBOOT task")
    retCode = 0
    sshKey = getSshKey(configuration)

    restartBaseTask = f'''- name: "AAA REBOOT"
  reboot: 
    reboot_timeout: 90
    msg: reboot via splunk action
  become: yes
  become_user: root
'''

    playbook = {'hosts': 'a','tasks':None}
    parsedTask = yaml.safe_load(restartBaseTask)
    playbook['tasks'] = parsedTask

    log(json.dumps(playbook), logging.DEBUG)

    hosts = configuration['hosts'].replace(',',"\n")

    log(hosts, logging.DEBUG)

    thread, ar_resp = ansible_runner.interface.run_async(playbook=[playbook],
                                                         inventory=f"[a]\n{hosts}",
                                                         json_mode=True, ssh_key=sshKey,
                                                         quiet=True, timeout=180)
    for event in ar_resp.events:
        log(json.dumps(event), logging.DEBUG)
        if event['event'].startswith('runner_on'):
            logEvent(event)
        if event['event'] == "runner_on_failed":
            retCode = 1
    log(f"Stats: {json.dumps(ar_resp.stats)}")

    return retCode


def runAdhocTask(configuration):
    retCode = 0
    sshKey = getSshKey(configuration)
    playbookDefault = {'hosts': 'alertHosts','gather_facts': False,'tasks':None}
    setup = configuration.get('play')
    parsedSetup = yaml.safe_load(setup)
    playbook = {**playbookDefault, **parsedSetup}

    playbook["connection"] = configuration.get('execLocation',"local")
    tasks = configuration.get('tasks')
    hosts = configuration['hosts'].replace(',',"\n")

    parsedTasks = yaml.safe_load(tasks)
    playbook["tasks"] = parsedTasks

    thread, ar_resp = ansible_runner.interface.run_async(playbook=[playbook],
                                                         inventory=f"[alertHosts]\n{hosts}",
                                                         json_mode=True, ssh_key=sshKey,
                                                         quiet=True)
    for event in ar_resp.events:
        log(json.dumps(event), logging.DEBUG)
        if event['event'].startswith('runner_on'):
            logEvent(event)
        if event['event'] == "runner_on_failed":
            retCode = 1
    log(f"Stats: {json.dumps(ar_resp.stats)}")

    return retCode

def main(argv):

    parser = argparse.ArgumentParser()

    parser.add_argument("--execute", required=True, action="store_true", help="Default param sent by splunk")
    parser.add_argument("--mode", required=True, action="store", choices=["REST","RESTART","REBOOT","ADHOC"], help="Mode to operate in")

    args = parser.parse_args(argv)

    payload = json.loads(sys.stdin.read())
    log(f"Args: {args} -- {json.dumps(payload)}")
    if args.mode == "REST":
        ret = runRestTask(payload['configuration'])
    elif args.mode == "RESTART":
        ret = runRestartTask(payload['configuration'])
    elif args.mode == "REBOOT":
        ret = runRebootTask(payload['configuration'])
    elif args.mode == "ADHOC":
        ret = runAdhocTask(payload['configuration'])
    else:
        log(f"Unknown mode {args.mode}", logging.ERROR)
        ret = 1

    log(f"Return Code: {ret}", logging.ERROR)

    sys.exit(ret)

if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
    #if len(sys.argv) > 1 and sys.argv[1] == "--execute":
    if len(sys.argv) > 1:
        sys.exit(main(sys.argv[1:]))
        payload = json.loads(sys.stdin.read())
        log(f"lgoc ansible_actions :: {sys.argv} -- {json.dumps(payload)}")
        # runTask(payload.get('configuration'))

        # if not send_message(payload.get('configuration')):
        #     log(f"lgoc {payload}", logging.FATAL)
        # else:
        #     log("Room notification successfully sent", logging.ERROR)
    else:
        log(f"Unsupported execution mode (expected --execute flag) :: {sys.argv}", logging.FATAL)
        sys.exit(1)
