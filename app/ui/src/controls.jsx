import { styled } from "@mui/material/styles";

/* Real `<input>` and `<select>` elements, styled - NOT MUI's `TextField` or
   `Select`.

   MUI forwards `data-testid` to the outermost wrapper `<div>`, and its
   non-native `Select` renders a `role="combobox"` div over a hidden input.
   Both put the stable id somewhere no `fill()` can reach and leave the real
   control anonymous, which is exactly backwards for a tree whose browser
   gate rides on those ids. A styled native element keeps the id on the thing
   the user (and Playwright) actually touches, and a native `<select>` is the
   better phone control anyway.

   44px min-height: the classic tree's controls sat at ~28px, below the touch
   floor. */

const base = ({ theme }) => ({
  minHeight: 44,
  padding: "0.5rem 0.6rem",
  fontSize: "1rem",
  fontFamily: "inherit",
  color: theme.palette.text.primary,
  background: theme.palette.background.paper,
  border: `1px solid ${theme.palette.divider}`,
  borderRadius: 6,
  boxSizing: "border-box",
  maxWidth: "100%",
});

export const TextInput = styled("input")(base);
export const SelectInput = styled("select")(base);

/* The traffic sparkline, carried over from the classic tree.

   A single bucket has no line segment to draw, so it becomes a flat stroke
   across the full width - otherwise one data point renders as nothing at
   all, which reads identically to "no data" and is a different claim. */
export function Sparkline({ rows, testid, height = 60 }) {
  const data = rows || [];
  const width = 300;
  const box = 60;
  let points = "";
  if (data.length) {
    const max = Math.max(...data.map((r) => r.up + r.down), 1);
    const step = width / Math.max(data.length - 1, 1);
    points = data.map((r, i) => {
      const y = box - ((r.up + r.down) / max) * (box - 4) - 2;
      return `${(i * step).toFixed(1)},${y.toFixed(1)}`;
    }).join(" ");
    if (data.length === 1) {
      const y = points.split(",")[1];
      points = `0,${y} ${width},${y}`;
    }
  }
  return (
    <svg
      data-testid={testid}
      viewBox={`0 0 ${width} ${box}`}
      preserveAspectRatio="none"
      style={{
        width: "100%", height, display: "block",
        background: "#fff", border: "1px solid #d7dde3", borderRadius: 6,
      }}
    >
      {points
        ? <polyline points={points} fill="none" stroke="#2563eb" strokeWidth="2" />
        : null}
    </svg>
  );
}
