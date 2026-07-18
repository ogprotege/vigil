declare module "qrcode-terminal" {
  interface GenerateOptions {
    small?: boolean;
  }
  export function generate(
    text: string,
    options?: GenerateOptions,
    callback?: (qr: string) => void
  ): void;
  export function setErrorLevel(level: "L" | "M" | "Q" | "H"): void;
}
