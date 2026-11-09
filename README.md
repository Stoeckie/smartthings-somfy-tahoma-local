# Somfy TaHoma (local) for SmartThings

SmartThings Edge driver for Somfy shades, screens, awnings and shutters on a **TaHoma box** (TaHoma Switch, TaHoma v2 and other boxes that support Developer Mode). It talks to the box over your LAN with Somfy's official local API, so no cloud and no bridge.

## What you get
* One device for the box, with **Connection** (Connected / Offline) and **Last drop**, usable in routines.
* A child device per shade, screen, awning or shutter on the box:
  * `windowShade` open / close / pause
  * `windowShadeLevel` 0 to 100 (100 = open), for io motors that report their position
  * `windowShadePreset`: the **My** position
* RTS motors (no position feedback) get open / close / pause / My; the app shows the last command.
* Changes from the Somfy app or a remote show up at the next poll (30 s by default, every 2 s for a minute after a command).
* Setting per shade: **Reverse direction**, if open and closed are swapped.

## Setup
1. **Developer Mode** in the TaHoma by Somfy app: Account > Configure the installation > open the parameters of your box and tap 7 times on the PIN of the box (like 2001-1234-5678). Then create a **token** in the Developer Mode menu and copy it right away (it is only shown once).
2. Give the box a fixed IP address in your router (DHCP reservation).
3. Install the driver from the channel, then in the SmartThings app: Add device > Scan nearby. A device **Somfy TaHoma** appears.
4. Open its settings and paste the token. Leave the IP on `auto` (found via mDNS `_kizboxdev._tcp`) or enter the IP of the box.
5. The shades appear as new devices within a minute.

The token stays on your hub (device setting) and is only sent to the box. The box uses a certificate from Somfy's own CA; the driver remembers that certificate on first use and never sends the token to a different one (enter the token again after replacing the box).

## Notes
* Local API: `https://<box>:8443/enduser-mobile-web/1/enduserAPI` (`GET /setup/devices`, `POST /exec/apply`), see [Somfy-TaHoma-Developer-Mode](https://github.com/Somfy-Developer/Somfy-TaHoma-Developer-Mode).
* Somfy `ClosureState` 0 = open, 100 = closed; `DeploymentState` 100 = deployed (sun blocked). SmartThings level 100 = open.
* The Somfy Connectivity Kit and the first square TaHoma box have no Developer Mode.
* Events: a value only goes to the hub when it changed (re-emitting everything every poll made the hub drop events, and the app then kept a stale position). After a driver start every value is sent once so the app catches up. A position the shade already has is not sent to the box (the app re-sends the shown value when a slider is opened and closed).

**Security (build 2026-11-09b):** a pinned gateway certificate that cannot be read any more now stops the token from being sent (before, pinning was skipped).

## License
Apache 2.0, see LICENSE. Not affiliated with Somfy.
