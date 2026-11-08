NETSCALER PRE-UPGRADE DISK CLEANUP

Frees space on your NetScaler appliances before an upgrade by removing old
builds from /var/nsinstall, then checks each appliance against the minimum
free space for the upgrade.

Run this BEFORE creating the upgrade job. It never starts an upgrade.

HOW TO RUN
1. Unzip NetScalerCleanup.zip on your management PC (keep the files together).
2. Open the folder and double-click "Run NetScaler Cleanup.bat".
   (If Windows says it blocked the file: delete the unzipped folder,
   right-click NetScalerCleanup.zip > Properties > tick "Unblock" > OK,
   then unzip again.)
3. In the window, enter:
     - your NetScaler IPs, one per line (both nodes of each HA pair)
     - your NetScaler username and password (the password is never saved)
4. Click "Test run" first. It shows exactly what would be deleted and
   deletes nothing.
5. If the list looks right, click "Real run" and confirm.

WHAT GETS DELETED (in /var/nsinstall)
  - old build folders (build-...) and old .tgz / .tar installer files

WHAT IS ALWAYS KEPT
  - adc.version and installns_state files
  - the build the appliance is running now (rollback), unless you untick it
  - any build newer than the running one (your upgrade image)
  - any builds you list under "Also keep these builds"
  - anything not recognised as a build file
Only folders under /var are ever touched. /flash is never touched.

RESULTS
  PASS   enough free space, ready for the upgrade job
  FAIL   still below the minimum after cleanup, needs manual attention
  ERROR  could not connect or log in, see the details box

Every run saves a .log and a .csv report in the "reports" folder.
Click "Open reports folder" to see them.

HOW IT CONNECTS
The tool uses NITRO, the connection built into every NetScaler (the same one
the NetScaler web page uses). It logs in with your normal NetScaler username
and password, works only inside your network, needs no internet, and sends
nothing anywhere else.
