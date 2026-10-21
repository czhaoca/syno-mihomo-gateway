import Box from "@mui/material/Box";
import { useTheme } from "@mui/material/styles";

import { fmtBytes } from "../stats.js";

/* A top-N list as horizontal bars (#100): ROWS [{key, label, up, down,
   href}], already in the order to show, each bar's length its total against
   the largest. One row element per value - `data-key`, `data-up`,
   `data-down` - for specs to count and read. Plain boxes rather than SVG: a
   label must wrap and be selectable, and a bar is a width. A row with an
   HREF drills (#101): its label is a native link, a 44px target. */
export default function TopBars({ testid, rows }) {
  const chart = useTheme().palette.chart;
  const max = Math.max(1, ...rows.map((r) => r.up + r.down));
  return (
    <Box data-testid={testid} sx={{ display: "grid", gap: 0.75 }}>
      {rows.map((row) => {
        const total = row.up + row.down;
        return (
          <Box key={row.key} data-testid={`${testid}-row`} data-key={row.key}
               data-up={row.up} data-down={row.down}
               sx={{ display: "grid", gap: 0.25 }}>
            <Box sx={{ display: "flex", justifyContent: "space-between", gap: 1,
                       alignItems: "center", fontSize: "0.85rem", minWidth: 0 }}>
              {row.href ? (
                <Box component="a" href={row.href}
                     data-testid={`${testid}-link`} data-key={row.key}
                     sx={{ overflowWrap: "anywhere", minWidth: 0,
                           minHeight: 44, display: "inline-flex",
                           alignItems: "center", color: "primary.main" }}>
                  {row.label}
                </Box>
              ) : (
                <Box component="span" sx={{ overflowWrap: "anywhere", minWidth: 0 }}>
                  {row.label}
                </Box>
              )}
              <Box component="span" sx={{ flex: "none", color: "text.secondary" }}>
                {fmtBytes(total)}
              </Box>
            </Box>
            <Box sx={{ display: "flex", height: 8, borderRadius: 1,
                       overflow: "hidden", bgcolor: chart.grid }}>
              <Box sx={{ width: `${(row.down / max) * 100}%`, bgcolor: chart.down }} />
              <Box sx={{ width: `${(row.up / max) * 100}%`, bgcolor: chart.up }} />
            </Box>
          </Box>
        );
      })}
    </Box>
  );
}
