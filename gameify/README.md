# Gameify — bastion completion scoring

Instructors score attendee progress by reading completion markers written when each attendee runs `setup/lab-cleanup.sh --module <id>` on their bastion.

Markers live in `~/.acs-roadshow/progress` as one line per module:

```text
Module 00 done
Module 101-01 done
```

## Setup

```bash
cd gameify
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

## CSV format

Columns (header required):

| Column   | Required | Default   | Description        |
|----------|----------|-----------|--------------------|
| host     | yes      | —         | Bastion hostname/IP |
| port     | no       | 22        | SSH port           |
| user     | no       | lab-user  | SSH username       |
| password | yes      | —         | SSH password       |

See [bastions.example.csv](bastions.example.csv).

## Usage

Score ACS modules `00`–`10` (default) across every row in a CSV:

```bash
python3 main.py --csv bastions.csv
```

Score a custom module list (role-track event):

```bash
python3 main.py --csv bastions.csv --modules 101-01,101-02,101-03
```

Quick single-host test:

```bash
python3 main.py -H ssh.example.com --port 30903 -P 'secret'
```

Results print to stdout and append to `results.log` in this directory.

## Attendee side

At the end of each lab module, attendees run the cleanup command from the guide (via `lab-cleanup.sh`). That script cleans lab resources and appends `Module <id> done` to `~/.acs-roadshow/progress`.
