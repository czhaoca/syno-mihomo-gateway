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

/* ---- the naming rule (#80 DEC-C, narrowed by #82) ------------------- */

/* A name has exactly one home. A HOST's name is its identity alias
   (`identity.host_key` keys on the /32; an operator's own edit outranks
   every importer). A RANGE cannot carry an alias at all, so its name
   lives in the policy row - the only home it can have. Migration v5
   emptied every host's `devices.name` and nothing in this interface
   writes one again, so the two-name state #80 had to explain is gone.

   `displayName` still reads `device.name` second, deliberately: for a
   range that IS the name, and for a host the field is dead storage the
   additive-only API may still hold - showing it when no alias exists
   beats showing "unnamed" while a name sits in the row. The precedence
   is applied HERE, once, and nowhere else. */

export function isHost(cidr) {
  return String(cidr).endsWith("/32");
}

export function hostIp(cidr) {
  return String(cidr).replace(/\/32$/, "");
}

export function displayName(device, unnamed) {
  return device.alias || device.name || unnamed;
}
