# SnapRAID Helper Script
Inspired by https://github.com/droolio/snapraid-helper

## Overview
This is a simplified SnapRAID helper script that is designed to be run daily. The script runs a sync each day and a scrub every X days, as defined in the .ini file. The script notifies of success or failure via Healthchecks.io. 

## Setup
1. Clone snapraid-helper-v2.ps1 and snapraid-helper.ini to a folder on your SnapRAID host. snapraid helper *must* be in the same folder as the script. 
2. Configure the settings in snapraid-helper.ini
3. Run the script daily using task scheduler, or whatever other mechanism you like. 