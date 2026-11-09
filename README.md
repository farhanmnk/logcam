# Get your .ipa without a Mac

1. Create a free GitHub account and a new empty repository (private is fine).
2. Upload everything in this folder (including the hidden .github folder) to it.
   Easiest: install GitHub Desktop, or use "Add file > Upload files" and drag the contents in.
3. Open the repo's Actions tab > "Build IPA" > Run workflow. Wait ~5-10 minutes.
4. Open the finished run, download the artifact "LogCam-ipa", unzip it to get LogCam.ipa.
5. Install it: the .ipa is unsigned, so use Sideloadly (Windows/Mac) or AltStore with your Apple ID.
   They sign it for you; free Apple IDs last 7 days.
6. On the iPhone: Settings > Privacy & Security > Developer Mode on, then trust the profile in
   Settings > General > VPN & Device Management.

If the build fails, open the failed run, copy the red error lines, and send them to me.
