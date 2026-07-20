import { describe, expect, it } from "vitest";
import { presentChunks, CLEAR_SCREEN } from "../src/qr/present.js";
import { renderQr } from "../src/qr/render.js";

function sink() {
  const out: string[] = [];
  const err: string[] = [];
  return { out, err, pushOut: (t: string) => out.push(t), pushErr: (t: string) => err.push(t) };
}

describe("presentChunks auto-sizing", () => {
  it("renders the big QR when the terminal is wide enough", async () => {
    const s = sink();
    const chunk = "vigil1:1/1:ABCD:" + "x".repeat(200);
    await presentChunks([chunk], { size: "auto" }, {
      out: s.pushOut,
      err: s.pushErr,
      columns: 500,
      clear: false,
    });
    expect(s.out.join("")).toContain(await renderQr(chunk, { big: true }));
  });

  it("falls back to the small QR when columns are unknown (non-TTY default)", async () => {
    const s = sink();
    const chunk = "vigil1:1/1:ABCD:" + "x".repeat(200);
    await presentChunks([chunk], { size: "auto" }, {
      out: s.pushOut,
      err: s.pushErr,
      clear: false,
    });
    expect(s.out.join("")).toContain(await renderQr(chunk, { big: false }));
  });

  it("warns when even the small QR is wider than the terminal", async () => {
    const s = sink();
    const chunk = "vigil1:1/1:ABCD:" + "x".repeat(200);
    await presentChunks([chunk], { size: "auto" }, {
      out: s.pushOut,
      err: s.pushErr,
      columns: 5,
      clear: false,
    });
    expect(s.err.join("")).toContain("too narrow");
  });
});

describe("presentChunks single chunk", () => {
  it("draws once, waits for a key, then clears when asked", async () => {
    const s = sink();
    let keyWaits = 0;
    await presentChunks(["vigil1:1/1:ABCD:data"], { size: "small" }, {
      out: s.pushOut,
      err: s.pushErr,
      columns: 500,
      clear: true,
      waitKey: async () => {
        keyWaits += 1;
      },
    });
    expect(keyWaits).toBe(1);
    expect(s.out.join("")).toContain("code 1 of 1");
    // The user must be told to press a key — otherwise the terminal looks stuck
    // and a Ctrl+C can abort before the screen is cleared.
    expect(s.err.join("")).toContain("press any key");
    expect(s.out.join("")).toContain(CLEAR_SCREEN);
  });

  it("does not clear when clear is false", async () => {
    const s = sink();
    await presentChunks(["vigil1:1/1:ABCD:data"], { size: "small" }, {
      out: s.pushOut,
      err: s.pushErr,
      columns: 500,
      clear: false,
      waitKey: async () => {},
    });
    expect(s.out.join("")).not.toContain(CLEAR_SCREEN);
  });
});

describe("presentChunks multi-chunk cycling", () => {
  it("cycles the codes in place until a key is pressed", async () => {
    const s = sink();
    let resolveKey!: () => void;
    const keyPromise = new Promise<void>((r) => {
      resolveKey = r;
    });
    let sleeps = 0;
    await presentChunks(["vigil1:1/3:ABCD:a", "vigil1:2/3:ABCD:b", "vigil1:3/3:ABCD:c"], { size: "small" }, {
      out: s.pushOut,
      err: s.pushErr,
      columns: 500,
      clear: true,
      waitKey: () => keyPromise,
      sleep: async () => {
        sleeps += 1;
        if (sleeps >= 3) resolveKey();
      },
    });
    const joined = s.out.join("");
    expect(joined).toContain("code 1 of 3");
    expect(joined).toContain("code 2 of 3");
    expect(joined).toContain("code 3 of 3");
    // Redraws in place (cursor-home escape), not by appending fresh frames forever.
    expect(joined).toContain("\x1b[H");
    expect(joined).toContain(CLEAR_SCREEN);
  });
});
