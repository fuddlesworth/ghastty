#pragma once

// sd_notify(3) integration — parity with the Zig core's src/os/systemd.zig.
//
// When ghastty runs as a systemd user service (e.g. the D-Bus-activated
// `app-com.ghastty.ghastty.service`, or a hand-written
// `app-ghastty@<id>.service`), systemd needs readiness/reload notifications:
//   - Type=notify        services must send READY=1 once startup completes,
//                        otherwise systemd waits for the notify and times out.
//   - Type=notify-reload services (the documented
//                        `systemctl --user reload ...` flow that sends SIGUSR2)
//                        must send RELOADING=1 then READY=1 around a reload,
//                        otherwise systemd considers the reload hung.
//
// All functions are no-ops when NOTIFY_SOCKET is unset (i.e. not launched by
// systemd), so they are always safe to call.
namespace systemd {

// Tell systemd we are ready / finished reloading. Sends "READY=1".
void notifyReady();

// Tell systemd a configuration reload has started. Sends
// "RELOADING=1\nMONOTONIC_USEC=<now>". Must be paired with a later
// notifyReady() once the reload finishes.
void notifyReloading();

}  // namespace systemd
