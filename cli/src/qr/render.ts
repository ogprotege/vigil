import qrcode from "qrcode-terminal";

/** Renders a QR to a string of terminal block characters. */
export function renderQr(text: string, opts: { big?: boolean } = {}): Promise<string> {
  return new Promise((resolve) => {
    qrcode.generate(text, { small: !opts.big }, (qr) => resolve(qr));
  });
}
