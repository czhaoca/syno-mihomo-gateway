import Box from "@mui/material/Box";
import { useTheme } from "@mui/material/styles";

/* One bar split into shares of a whole (#100): SEGMENTS
   [{key, label, share, tone, permanent}] with share in percent and TONE a
   theme chart token. A PERMANENT segment - "unattributed" - is always
   rendered and always listed, even at 0 %, because a share that vanishes
   when it is small reads as a share that does not exist. Each segment
   carries `data-share`. */
export default function ShareBar({ testid, segments }) {
  const chart = useTheme().palette.chart;
  const shown = segments.filter((s) => s.permanent || s.share > 0);
  return (
    <Box data-testid={testid}>
      <Box sx={{ display: "flex", height: 12, borderRadius: 1, overflow: "hidden",
                 bgcolor: chart.grid, border: 1, borderColor: chart.border }}>
        {shown.map((s) => (
          <Box key={s.key} data-testid={`${testid}-${s.key}`}
               data-share={s.share.toFixed(1)}
               sx={{ width: `${Math.max(s.share, 0)}%`, bgcolor: chart[s.tone] }} />
        ))}
      </Box>
      <Box sx={{ display: "flex", flexWrap: "wrap", gap: 1.5, mt: 0.5,
                 fontSize: "0.8rem", color: "text.secondary" }}>
        {shown.map((s) => (
          <Box key={s.key} data-testid={`${testid}-label-${s.key}`}
               sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
            <Box sx={{ width: 10, height: 10, borderRadius: 0.5, flex: "none",
                       bgcolor: chart[s.tone] }} />
            {`${s.label} ${s.share.toFixed(1)}%`}
          </Box>
        ))}
      </Box>
    </Box>
  );
}
