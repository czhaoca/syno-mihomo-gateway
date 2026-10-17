import Box from "@mui/material/Box";
import { useTheme } from "@mui/material/styles";

/* Swatches for what a chart draws. ITEMS: [{key, label, tone, hatch,
   region}] - TONE names a theme chart token, so the legend and the marks
   can never disagree about a colour; a REGION swatch is outlined dashed in
   the axis token, as the region itself is. */
export default function Legend({ testid, items }) {
  const chart = useTheme().palette.chart;
  return (
    <Box data-testid={testid} sx={{
      display: "flex", flexWrap: "wrap", gap: 1.5, fontSize: "0.8rem",
      color: "text.secondary", mt: 0.5,
    }}>
      {items.map((item) => (
        <Box key={item.key} data-testid={`${testid}-${item.key}`}
             sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
          <Box sx={{
            width: 12, height: 12, borderRadius: 0.5, flex: "none",
            bgcolor: item.hatch ? "transparent" : chart[item.tone],
            backgroundImage: item.hatch ? `repeating-linear-gradient(45deg, ${
              chart[item.tone]} 0 2px, transparent 2px 4px)` : "none",
            border: 1, borderColor: item.region ? chart.axis : chart.border,
            borderStyle: item.region ? "dashed" : "solid",
          }} />
          {item.label}
        </Box>
      ))}
    </Box>
  );
}
