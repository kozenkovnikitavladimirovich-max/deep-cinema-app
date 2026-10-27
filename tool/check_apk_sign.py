"""Проверка: APK подписан постоянным ключом tool/assets/signing.keystore.
Иначе обновление на телевизоре не встанет поверх («Приложение не установлено»)."""
import hashlib
import struct
import subprocess
import sys


def apk_cert_sha256(path):
    d = open(path, 'rb').read()
    eocd = d.rfind(b'PK\x05\x06')
    cd = struct.unpack('<I', d[eocd + 16:eocd + 20])[0]
    if d[cd - 16:cd] != b'APK Sig Block 42':
        raise SystemExit('нет блока подписи v2')
    size = struct.unpack('<Q', d[cd - 24:cd - 16])[0]
    pos = cd - size - 8 + 8
    blocks = {}
    while pos < cd - 24:
        ln, = struct.unpack('<Q', d[pos:pos + 8])
        idv, = struct.unpack('<I', d[pos + 8:pos + 12])
        blocks[idv] = d[pos + 12:pos + 8 + ln]
        pos += 8 + ln
    v = blocks.get(0x7109871a) or blocks.get(0xf05368c0)

    def lp(b, o):
        n, = struct.unpack('<I', b[o:o + 4])
        return b[o + 4:o + 4 + n], o + 4 + n

    signers, _ = lp(v, 0)
    signer, _ = lp(signers, 0)
    sd, _ = lp(signer, 0)
    _, o = lp(sd, 0)
    certs, _ = lp(sd, o)
    cert, _ = lp(certs, 0)
    return hashlib.sha256(cert).hexdigest().upper()


def keystore_sha256(path):
    out = subprocess.run(['keytool', '-list', '-v', '-keystore', path, '-storepass', 'android'], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if 'SHA256:' in line:
            return line.split('SHA256:')[1].strip().replace(':', '').upper()
    raise SystemExit('не прочитан ключ')


if __name__ == '__main__':
    apk, ks = sys.argv[1], sys.argv[2]
    a, k = apk_cert_sha256(apk), keystore_sha256(ks)
    print('APK:', a)
    print('Ключ:', k)
    if a != k:
        print('::error title=Подпись APK::APK подписан не постоянным ключом — обновление не встанет поверх')
        sys.exit(1)
    print('Подпись в порядке')
