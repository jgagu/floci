#!/usr/bin/env python3
"""
Proxy TLS temporal para usar azurerm_key_vault con Floci-AZ sin permisos de administrador.

Terraform abre un túnel HTTP CONNECT a través de HTTPS_PROXY. Este proceso termina TLS
con el certificado wildcard de Floci-AZ, adapta exclusivamente las solicitudes Key Vault y
las reenvía a https://localhost:4577/{vault}-keyvault/.

Cambios aplicados a cada solicitud:
  - /ruta                -> /{vault}-keyvault/ruta
  - Host                 -> localhost:4577
  - Authorization Bearer -> Bearer fake-token

No modifica hosts, DNS, netsh ni variables de entorno persistentes.
"""

from __future__ import annotations

import argparse
import socket
import ssl
import sys
import threading
from pathlib import Path

LISTEN_HOST = "127.0.0.1"
DEFAULT_PORT = 18080
FLOCI_HOST = "localhost"
FLOCI_PORT = 4577
MAX_HEADER_SIZE = 64 * 1024
ALLOWED_SUFFIX = ".vault.azure.net"


def read_until(sock: socket.socket, marker: bytes, limit: int = MAX_HEADER_SIZE) -> bytes:
    data = bytearray()
    while marker not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("La conexión se cerró antes de completar las cabeceras.")
        data.extend(chunk)
        if len(data) > limit:
            raise ValueError("Las cabeceras exceden el tamaño máximo permitido.")
    return bytes(data)


def send_response(sock: socket.socket, status: str) -> None:
    sock.sendall(f"HTTP/1.1 {status}\r\nConnection: close\r\n\r\n".encode("ascii"))


def parse_connect_target(request_line: str) -> tuple[str, int] | None:
    parts = request_line.split(" ", 2)
    if len(parts) < 2 or parts[0].upper() != "CONNECT":
        return None

    host_port = parts[1].rsplit(":", 1)
    if len(host_port) != 2:
        return None

    try:
        return host_port[0].lower(), int(host_port[1])
    except ValueError:
        return None


def content_length(headers: list[str]) -> int:
    for header in headers:
        name, _, value = header.partition(":")
        if name.lower() == "content-length":
            return int(value.strip())
    return 0


def rewrite_request(raw_header: bytes, vault_name: str) -> tuple[bytes, int]:
    text = raw_header.decode("iso-8859-1")
    lines = text.split("\r\n")
    method, target, version = lines[0].split(" ", 2)

    if not target.startswith("/"):
        raise ValueError("La solicitud Key Vault debe usar una ruta absoluta.")

    prefix = f"/{vault_name}-keyvault"
    if not target.startswith(prefix + "/") and target != prefix:
        target = prefix + target

    headers: list[str] = []
    found_authorization = False
    for header in lines[1:]:
        if not header:
            continue
        name, separator, _ = header.partition(":")
        if not separator:
            continue

        lowered = name.lower()
        if lowered == "authorization":
            headers.append("Authorization: Bearer fake-token")
            found_authorization = True
        elif lowered == "host":
            headers.append(f"Host: {FLOCI_HOST}:{FLOCI_PORT}")
        elif lowered == "proxy-connection":
            continue
        else:
            headers.append(header)

    if not found_authorization:
        headers.append("Authorization: Bearer fake-token")

    body_size = content_length(headers)
    rewritten = (f"{method} {target} {version}\r\n" + "\r\n".join(headers) + "\r\n\r\n")
    return rewritten.encode("iso-8859-1"), body_size


def copy_response(upstream: ssl.SSLSocket, client_tls: ssl.SSLSocket) -> None:
    while True:
        chunk = upstream.recv(8192)
        if not chunk:
            break
        client_tls.sendall(chunk)


def handle_client(
    client: socket.socket,
    inbound_tls: ssl.SSLContext,
    outbound_tls: ssl.SSLContext,
    vault_name: str,
) -> None:
    with client:
        client.settimeout(20)
        try:
            connect_header = read_until(client, b"\r\n\r\n")
            request_line = connect_header.split(b"\r\n", 1)[0].decode("ascii", errors="replace")
            destination = parse_connect_target(request_line)

            if destination is None:
                send_response(client, "405 Method Not Allowed")
                return

            hostname, port = destination
            expected_hostname = f"{vault_name}{ALLOWED_SUFFIX}"
            if hostname != expected_hostname or port != 443:
                send_response(client, "403 Forbidden")
                return

            client.sendall(
                b"HTTP/1.1 200 Connection Established\r\n"
                b"Proxy-Agent: FlociKeyVaultTlsProxy\r\n\r\n"
            )

            with inbound_tls.wrap_socket(client, server_side=True) as client_tls:
                client_tls.settimeout(30)
                raw_header = read_until(client_tls, b"\r\n\r\n")
                request_header, body_size = rewrite_request(raw_header, vault_name)
                body = b""
                while len(body) < body_size:
                    chunk = client_tls.recv(body_size - len(body))
                    if not chunk:
                        raise ConnectionError("La solicitud terminó antes de completar el cuerpo.")
                    body += chunk

                with socket.create_connection((FLOCI_HOST, FLOCI_PORT), timeout=20) as upstream_socket:
                    with outbound_tls.wrap_socket(upstream_socket, server_hostname=FLOCI_HOST) as upstream:
                        upstream.sendall(request_header + body)
                        copy_response(upstream, client_tls)

        except (ConnectionError, OSError, ValueError, ssl.SSLError) as error:
            print(f"[proxy] conexión rechazada/fallida: {error}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Proxy TLS temporal para Key Vault de Floci-AZ."
    )
    parser.add_argument("--vault", default="keyvault", help="Nombre del Key Vault (predeterminado: keyvault).")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Puerto local (predeterminado: {DEFAULT_PORT}).")
    parser.add_argument(
        "--cert",
        type=Path,
        default=Path("data/tls/floci-az-selfsigned.crt"),
        help="Certificado PEM de servidor generado por Floci-AZ.",
    )
    parser.add_argument(
        "--key",
        type=Path,
        default=Path("data/tls/floci-az-selfsigned.key"),
        help="Clave PEM de servidor generada por Floci-AZ.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if not 1024 <= args.port <= 65535:
        print("El puerto debe estar entre 1024 y 65535.", file=sys.stderr)
        return 2

    if not args.vault.replace("-", "").isalnum():
        print("El nombre del vault solo puede contener letras, números y guiones.", file=sys.stderr)
        return 2

    if not args.cert.is_file() or not args.key.is_file():
        print(
            "No se encontró el certificado o la clave de Floci-AZ. "
            "Inicia primero el contenedor para que genere data/tls/.",
            file=sys.stderr,
        )
        return 2

    inbound_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    inbound_tls.load_cert_chain(certfile=args.cert, keyfile=args.key)

    # La conexión ascendente es solo a localhost; la CA se valida en el cliente Terraform.
    outbound_tls = ssl.create_default_context()
    outbound_tls.check_hostname = False
    outbound_tls.verify_mode = ssl.CERT_NONE

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((LISTEN_HOST, args.port))
        server.listen(32)

        print(f"Proxy TLS de Floci-AZ activo en http://{LISTEN_HOST}:{args.port}")
        print(f"Vault permitido: {args.vault}{ALLOWED_SUFFIX}:443")
        print(f"Destino local: https://{FLOCI_HOST}:{FLOCI_PORT}/{args.vault}-keyvault/")
        print("Autorización adaptada a: Bearer fake-token")
        print("Pulsa Ctrl+C para detenerlo.")

        try:
            while True:
                client, _ = server.accept()
                threading.Thread(
                    target=handle_client,
                    args=(client, inbound_tls, outbound_tls, args.vault),
                    daemon=True,
                ).start()
        except KeyboardInterrupt:
            print("\nProxy detenido.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
