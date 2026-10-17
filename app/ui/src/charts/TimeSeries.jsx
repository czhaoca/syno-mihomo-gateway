import { useId, useRef, useState } from "react";
import Box from "@mui/material/Box";
import { useTheme } from "@mui/material/styles";

import { fmtBytes } from "../stats.js";
import Axis from "./Axis.jsx";
import Legend from "./Legend.jsx";
import Tooltip from "./Tooltip.jsx";

/* Stacked up/down bars over a bucket grid (#100; see grid.js for what each
   bucket may claim). One mark per grid cell - `data-bucket`, `data-up`,
   `data-down`, `data-gap` ("", "partial", "full"), `data-seam` - so a spec
   counts and reads marks, never pixels. A value-less gap is a hatched band
   the full height of the chart (a hole, never a zero); a partial gap keeps
   its bar under a hatched cap; a seam is a marker line before its bar; the
   span before the data starts and the one after the last good poll are
   flat, unmarked regions. Marks are drawn at full strength; the selected
   bucket is outlined, never shown by dimming the rest.

   The SVG scales to its container's width (viewBox units are slots), so
   nothing here measures the page. The pointer or the arrow keys pick a
   bucket and the DOM tooltip names it - the chart is one focus stop, and
   every mark is reachable from it. COMPACT drops the axis and the legend
   (a device row's strip). */
const HEIGHT = 100;

export default function TimeSeries({ grid, testid, t, height = 140,
                                      compact = false }) {
  const chart = useTheme().palette.chart;
  const uid = useId().replace(/:/g, "");
  const box = useRef(null);
  // the selection is a BUCKET (its key and its bar within that key), not an
  // index: a refresh can drop or add buckets, and an index would then point
  // at another bucket - or past the end
  const [picked, setPicked] = useState(null);
  const units = Math.max(grid.units, 1);
  const max = Math.max(grid.max, 1);
  const cells = grid.cells;
  const idOf = (i) => (i === null || !cells[i] ? null
    : `${cells[i].key}|${cells[i].framing || ""}`);
  const found = picked === null ? -1 : cells.findIndex((_c, i) => idOf(i) === picked);
  const active = found === -1 ? null : found;
  const setActive = (next) => {
    const value = typeof next === "function" ? next(active) : next;
    setPicked(idOf(value));
  };

  const at = (slot) => {
    const i = cells.findIndex((c) => slot >= c.x && slot < c.x + c.width);
    return i === -1 ? null : i;
  };
  const onPointer = (evt) => {
    const rect = box.current.getBoundingClientRect();
    if (!rect.width) return;
    setActive(at(((evt.clientX - rect.left) / rect.width) * units));
  };
  const onKey = (evt) => {
    if (!cells.length) return;
    const last = cells.length - 1;
    const moves = { ArrowRight: 1, ArrowLeft: -1 };
    if (evt.key in moves) {
      evt.preventDefault();
      setActive((i) => (i === null ? (moves[evt.key] > 0 ? 0 : last)
        : Math.min(Math.max(i + moves[evt.key], 0), last)));
    } else if (evt.key === "Home") {
      setActive(0);
    } else if (evt.key === "End") {
      setActive(last);
    } else if (evt.key === "Escape") {
      setActive(null);
    }
  };

  const lines = active === null ? null : describe(cells[active], t);
  const tipAt = active === null || !cells[active] ? null
    : ((cells[active].x + cells[active].width / 2) / units) * 100;
  const scale = (v) => (v / max) * (HEIGHT - 6);
  const hatch = `${uid}-hatch`;

  return (
    <Box data-testid={testid ? `${testid}-chart` : undefined}>
      <Box
        ref={box}
        tabIndex={0}
        role="group"
        aria-label={t("chart_aria")}
        data-testid={testid ? `${testid}-focus` : undefined}
        onPointerMove={onPointer}
        onPointerDown={onPointer}
        // a finger lifting fires pointerleave: on touch the tooltip stays
        // until the next tap or a blur
        onPointerLeave={(evt) => {
          if (evt.pointerType === "mouse") setActive(null);
        }}
        onFocus={() => setActive((i) => (i === null && cells.length ? 0 : i))}
        onBlur={() => setActive(null)}
        onKeyDown={onKey}
        sx={{ position: "relative", outline: "none", borderRadius: 1.5,
              "&:focus-visible": { boxShadow: `0 0 0 2px ${chart.up}` } }}
      >
        <svg
          aria-hidden="true"
          data-testid={testid}
          viewBox={`0 0 ${units} ${HEIGHT}`}
          preserveAspectRatio="none"
          style={{ width: "100%", height, display: "block",
                   background: chart.surface, border: `1px solid ${chart.border}`,
                   borderRadius: 6 }}
        >
          <defs>
            <pattern id={hatch} patternUnits="userSpaceOnUse"
                     width={Math.max(units / 60, 0.6)} height="8"
                     patternTransform="rotate(45)">
              <rect width={Math.max(units / 120, 0.3)} height="8"
                    fill={chart.gap} />
            </pattern>
          </defs>
          {grid.before ? (
            <rect data-testid={testid ? `${testid}-before` : undefined}
                  x={grid.before.from} y="0"
                  width={grid.before.to - grid.before.from} height={HEIGHT}
                  fill={chart.before} stroke={chart.axis} strokeWidth="1"
                  strokeDasharray="2 3" vectorEffect="non-scaling-stroke" />
          ) : null}
          {grid.stale ? (
            <rect data-testid={testid ? `${testid}-stale-band` : undefined}
                  x={grid.stale.from} y="0"
                  width={grid.stale.to - grid.stale.from} height={HEIGHT}
                  fill={chart.stale} stroke={chart.axis} strokeWidth="1"
                  strokeDasharray="6 3" vectorEffect="non-scaling-stroke" />
          ) : null}
          {cells.map((cell, i) => {
            const pad = cell.width * 0.08;
            const x = cell.x + pad;
            const w = Math.max(cell.width - 2 * pad, 0.05);
            const mark = {
              "data-bucket": cell.key,
              "data-gap": cell.gap,
              "data-seam": cell.seam ? "true" : "false",
            };
            if (cell.gap === "full") {
              return (
                <rect key={`${cell.key}:${i}`} {...mark} data-mark="1"
                      x={cell.x} y="0" width={cell.width} height={HEIGHT}
                      fill={`url(#${hatch})`} />
              );
            }
            const down = scale(cell.down);
            const up = scale(cell.up);
            return (
              <g key={`${cell.key}:${i}`}>
                {cell.seam ? (
                  <line data-seam-marker="1" x1={cell.x} x2={cell.x} y1="0"
                        y2={HEIGHT} stroke={chart.seam} strokeWidth="2"
                        vectorEffect="non-scaling-stroke" />
                ) : null}
                <rect {...mark} data-mark="1" data-up={cell.up}
                      data-down={cell.down} x={x} y={HEIGHT - down - up}
                      width={w} height={up} fill={chart.up} />
                <rect x={x} y={HEIGHT - down} width={w} height={down}
                      fill={chart.down} />
                {cell.gap === "partial" ? (
                  <rect x={cell.x} y="0" width={cell.width} height="10"
                        fill={`url(#${hatch})`} />
                ) : null}
              </g>
            );
          })}
          {/* the selected bucket is OUTLINED - every mark stays at full
              strength, because a dimmed token can fall below the contrast
              its full-strength value was chosen for */}
          {tipAt === null ? null : (
            <rect data-selected="1" x={cells[active].x} y="0"
                  width={cells[active].width} height={HEIGHT} fill="none"
                  stroke={chart.axis} strokeWidth="2"
                  vectorEffect="non-scaling-stroke" />
          )}
        </svg>
        <Tooltip testid={testid ? `${testid}-tooltip` : undefined} at={tipAt}
                 lines={lines} />
      </Box>
      {compact ? null : (
        <>
          <Axis testid={`${testid}-axis`} start={grid.axisStart}
                end={grid.axisEnd} top={grid.max ? fmtBytes(grid.max) : ""} />
          <Legend testid={`${testid}-legend`} items={legendItems(grid, t)} />
        </>
      )}
    </Box>
  );
}

function describe(cell, t) {
  if (!cell) return null;
  const out = [cell.framing ? `${cell.key} (${cell.framing})` : cell.key];
  if (cell.gap === "full") {
    out.push(t("chart_gap"));
    return out;
  }
  out.push(`${t("chart_up")}: ${fmtBytes(cell.up)}`);
  out.push(`${t("chart_down")}: ${fmtBytes(cell.down)}`);
  if (cell.gap === "partial") out.push(t("chart_gap_partial"));
  if (cell.seam) out.push(t("chart_seam"));
  return out;
}

function legendItems(grid, t) {
  const items = [
    { key: "up", label: t("chart_up"), tone: "up" },
    { key: "down", label: t("chart_down"), tone: "down" },
  ];
  if (grid.cells.some((c) => c.gap)) {
    items.push({ key: "gap", label: t("chart_gap"), tone: "gap", hatch: true });
  }
  if (grid.cells.some((c) => c.seam)) {
    items.push({ key: "seam", label: t("chart_seam"), tone: "seam" });
  }
  if (grid.before) {
    items.push({ key: "before", label: t("chart_before"), tone: "before",
                 region: true });
  }
  if (grid.stale) {
    items.push({ key: "stale", label: t("chart_stale_band"), tone: "stale",
                 region: true });
  }
  return items;
}
