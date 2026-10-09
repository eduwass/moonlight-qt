// Fork-only (eduwass/moonlight-qt): which network the stream travels over.
//
// Moonlight tries a host's saved addresses in turn and uses the first that
// answers, so a stream can end up on Wi-Fi or a VPN while a cable to the same
// host sits unused, and nothing shows it: the picture is the same, only
// slower. This names the path in the log when a session starts and in the
// statistics overlay (Ctrl+Alt+Shift+S).

#include <QHostAddress>
#include <QNetworkInterface>
#include <QUdpSocket>

#include "SDL_compat.h"

static char s_Path[96] = "unknown";

static const char* kindOf(const QNetworkInterface& nic)
{
    QString name = nic.name();
    if (name.startsWith("utun") || name.startsWith("tun") || name.startsWith("wg") || name.startsWith("tailscale")) {
        return "VPN";
    }
#ifdef Q_OS_DARWIN
    // macOS puts Thunderbolt networking behind a bridge, and Internet Sharing
    // too, so this is a likelihood and worded as one.
    if (name.startsWith("bridge")) {
        return "bridge, usually Thunderbolt";
    }
#endif
    switch (nic.type()) {
    case QNetworkInterface::Wifi:
        return "Wi-Fi";
    case QNetworkInterface::Ethernet:
        return "Ethernet";
    default:
        return "other";
    }
}

const char* netPath()
{
    return s_Path;
}

void netPathUpdate(const QString& host)
{
    QByteArray via = "unknown interface";

    // Only for a literal address: a name would have to be resolved, which can
    // block, and could resolve to another address than the stream uses.
    QHostAddress local;
    if (!QHostAddress(host).isNull()) {
        // Connecting a UDP socket sends nothing. It only makes the system
        // choose the local address it would reach the host from.
        QUdpSocket probe;
        probe.connectToHost(host, 47998);
        probe.waitForConnected(1000);
        local = probe.localAddress();
    }

    for (const QNetworkInterface& nic : QNetworkInterface::allInterfaces()) {
        for (const QNetworkAddressEntry& entry : nic.addressEntries()) {
            if (!local.isNull() && entry.ip().isEqual(local, QHostAddress::TolerantConversion)) {
                via = nic.name().toUtf8() + " (" + kindOf(nic) + ")";
            }
        }
    }

    SDL_snprintf(s_Path, sizeof(s_Path), "%s via %s", host.toUtf8().constData(), via.constData());
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Network path: %s", s_Path);
}
