/* Address arithmetic and the naming rule, kept out of the components so
   both are testable as plain functions and neither is re-derived per view. */

/* IPv4 CIDR overlap for the pre-add band confirm (mirrors the server's
   canonical form; a non-IPv4 input just skips the client-side gate - the
   server validates for real). */
export function cidrRange(cidr) {
  const [ip, lenRaw] = String(cidr).split("/");
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => Number.isNaN(n) || n > 255)) {
    return null;
  }
  const len = lenRaw === undefined ? 32 : Number(lenRaw);
  if (Number.isNaN(len) || len < 0 || len > 32) return null;
  const base = ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8)
                | parts[3]) >>> 0;
  const mask = len === 0 ? 0 : (0xFFFFFFFF << (32 - len)) >>> 0;
  const lo = (base & mask) >>> 0;
  return [lo, (lo | (~mask >>> 0)) >>> 0];
}

export function inBand(address, band) {
  const range = cidrRange(address);
  if (!range) return false;
  return band.some((entry) => {
    const b = cidrRange(entry);
    return b && range[0] <= b[1] && b[0] <= range[1];
  });
}

/* ---- the naming rule (#80 DEC-C) ------------------------------------ */

/* A device can carry TWO independent human names, and until now no
   precedence rule existed anywhere - deliberately, so that it could be
   applied ONCE in the interface rather than guessed at per call site.

   `alias` is the identity-layer name: it survives the policy being removed
   and an operator's own edit outranks every importer. `devices.name` lives
   inside the policy row and is destroyed with it. So the alias wins - but
   only where it can exist at all. `identity.host_key` refuses anything
   wider than a /32, so a RANGE can never carry one and its `name` is
   simply its name, exactly as before. */

export function isHost(cidr) {
  return String(cidr).endsWith("/32");
}

export function hostIp(cidr) {
  return String(cidr).replace(/\/32$/, "");
}

export function displayName(device, unnamed) {
  return device.alias || device.name || unnamed;
}

/* The `devices.name` of a host row that the alias has displaced. Shown, never
   hidden: dropping a stored name from the interface is the only version of
   this rule that would be a lie. Empty for a range (its name is not
   displaced by anything) and empty when the two agree. */
export function displacedName(device) {
  if (!isHost(device.cidr) || !device.alias) return "";
  return device.name && device.name !== device.alias ? device.name : "";
}
