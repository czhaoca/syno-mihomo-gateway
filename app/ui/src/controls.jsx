import { styled } from "@mui/material/styles";

import TimeSeries from "./charts/TimeSeries.jsx";
import { sparseGrid } from "./charts/grid.js";

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

/* A traffic strip (#100): the chart kit's series in its compact form, over
   the rows ALONE - no zero-fill, because a strip like a device's history
   reads no gap list, and a missing bucket there is a break, never a zero
   drawn across it (grid.js `sparseGrid`). Every colour comes from the
   theme. */
export function Sparkline({ rows, testid, height = 60, tier = null,
                           t = (k) => k }) {
  return (
    <TimeSeries grid={sparseGrid(rows, tier)} testid={testid} t={t}
                height={height} compact />
  );
}
