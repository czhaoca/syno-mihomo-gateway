import { useCallback, useEffect, useRef, useState } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import Card from "@mui/material/Card";
import Stack from "@mui/material/Stack";
import Table from "@mui/material/Table";
import TableBody from "@mui/material/TableBody";
import TableCell from "@mui/material/TableCell";
import TableContainer from "@mui/material/TableContainer";
import TableHead from "@mui/material/TableHead";
import TableRow from "@mui/material/TableRow";
import Typography from "@mui/material/Typography";
import useMediaQuery from "@mui/material/useMediaQuery";

import { api } from "../api.js";
import { FOLD_PX } from "../theme.js";

/* The audit log, readable at both ends (#80 DEC-B).

   Below 760px it is a stack of cards, one per entry; above it, a real table.
   That is a COMPONENT SWAP, not one table forced to `display: block` by a
   media query - which is what the classic tree did, and why that markup
   needed explicit `role="table"/"row"/"cell"` attributes to put back the
   semantics the display override destroyed. Two real trees need no such
   repair, and the fold labels become real text nodes rather than
   `content: attr(data-label)`: generated content is inconsistently exposed
   to assistive technology, can be dropped under forced-colors, and is
   neither selectable nor findable with Ctrl-F.

   Column priority is preserved in BOTH layouts. Time, target and requester
   are atomic tokens - an ISO stamp, a CIDR, an IP - and must never wrap:
   removing `word-break` is not enough on its own, because the default line
   breaker still offers a break after the `/` in a CIDR. The note is the only
   free-text column and is the one place an intra-word break is right. */

const PAGE = 50;

const COLUMNS = [
  { field: "time", label: "col_time", atomic: true },
  { field: "action", label: "col_action", atomic: false },
  { field: "target", label: "col_target", atomic: true },
  { field: "requester", label: "col_requester", atomic: true },
  { field: "note", label: "col_note", atomic: false },
];

const atomicSx = {
  whiteSpace: "nowrap", fontFamily: "ui-monospace, monospace",
  fontSize: "0.82rem", fontVariantNumeric: "tabular-nums",
};
const freeSx = { overflowWrap: "anywhere" };

function cellSx(column) {
  return column.atomic ? atomicSx : freeSx;
}

export default function AuditView({ t, tick }) {
  const [entries, setEntries] = useState([]);
  const [offset, setOffset] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const [stale, setStale] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const wide = useMediaQuery(`(min-width:${FOLD_PX}px)`);

  // The offset actually PAINTED, which is not always the one we asked for: a
  // superseded or failed load leaves the table showing an older page.
  const shown = useRef(0);
  // Monotonic request id - a slow answer for an abandoned page must never
  // repaint over a newer one, or the rows and the pager disagree.
  const generation = useRef(0);
  const offsetRef = useRef(0);
  // The view is conditionally mounted, so entering the tab runs EVERY effect
  // including the tick one - and `tick` is non-zero after the session's first
  // ten seconds. Without this the mount fetched the same page twice.
  const mounted = useRef(false);

  useEffect(() => { offsetRef.current = offset; }, [offset]);

  const load = useCallback(async (target) => {
    const mine = generation.current + 1;
    generation.current = mine;
    // One more row than we show: its presence is the only honest "there is a
    // next page" signal the API offers, and without it a log whose length is
    // an exact multiple of the page size leaves Older enabled onto a blank
    // page.
    const { status, data } = await api(
      "GET", `/v1/audit?limit=${PAGE + 1}&offset=${target}`);
    if (mine !== generation.current) return true;
    if (status !== 200) {
      // Keep whatever is on screen, but never let it pass for current - a
      // silently frozen audit log is the bug this replaced.
      setStale(true);
      return false;
    }
    setStale(false);
    setHasMore(data.entries.length > PAGE);
    setEntries(data.entries.slice(0, PAGE));
    shown.current = target;
    setLoaded(true);
    return true;
  }, []);

  // Entering the tab lands on the newest page.
  useEffect(() => { load(0); }, [load]);

  /* Older pages are a snapshot: re-fetching a raw offset while new entries
     push rows down would duplicate some and skip others, so the auto-refresh
     is confined to the first page and a deeper one says it is frozen. */
  useEffect(() => {
    if (!mounted.current) { mounted.current = true; return; }
    if (offsetRef.current !== 0) return;
    load(0);
  }, [tick, load]);

  const page = async (delta) => {
    const next = offset + delta * PAGE;
    if (next < 0) return;
    setOffset(next);
    // A page turn that never landed must not leave the offset ahead of the
    // table, or the next click jumps two pages and quietly skips the one in
    // between. Fall back to what is actually on screen - the page we last
    // INTENDED may itself never have been painted.
    if (await load(next) === false) setOffset(shown.current);
  };

  const values = (e) => {
    const translated = t(`action_${e.action}`);
    return {
      time: e.ts,
      action: translated === `action_${e.action}` ? e.action : translated,
      target: [e.cidr, e.mode].filter(Boolean).join(" "),
      requester: e.requester,
      note: e.note || e.details || "",
    };
  };

  return (
    <Stack spacing={1.5}>
      {wide ? (
        <TableContainer sx={{ overflowX: "auto" }}>
          <Table size="small" data-testid="audit-table">
            <TableHead>
              <TableRow>
                {COLUMNS.map((c) => (
                  <TableCell key={c.field}>{t(c.label)}</TableCell>
                ))}
              </TableRow>
            </TableHead>
            <TableBody data-testid="audit-rows">
              {entries.map((e, i) => {
                const v = values(e);
                return (
                  <TableRow key={`${e.ts}:${i}`}>
                    {COLUMNS.map((c) => (
                      <TableCell key={c.field} data-field={c.field}
                                 sx={cellSx(c)}>
                        {v[c.field]}
                      </TableCell>
                    ))}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      ) : (
        <Stack spacing={1} data-testid="audit-cards">
          {entries.map((e, i) => {
            const v = values(e);
            return (
              <Card key={`${e.ts}:${i}`} variant="outlined" sx={{ p: 1 }}
                    data-testid="audit-card">
                {COLUMNS.map((c) => (
                  // The note is the only OPTIONAL field - drop it when absent
                  // rather than leaving a labelled blank line on every card.
                  // Every other field stays even when empty, so a card always
                  // shows the same shape.
                  c.field === "note" && !v.note ? null : (
                    <Stack key={c.field} direction="row" spacing={1}
                           justifyContent="space-between" alignItems="baseline">
                      <Typography variant="caption" color="text.secondary"
                                  sx={{ flex: "0 0 auto" }}>
                        {t(c.label)}
                      </Typography>
                      <Box data-field={c.field}
                           sx={{ ...cellSx(c), textAlign: "right", minWidth: 0 }}>
                        {v[c.field]}
                      </Box>
                    </Stack>
                  )
                ))}
              </Card>
            );
          })}
        </Stack>
      )}

      {/* Say something whenever there is nothing to show. A later page can
          come back empty if entries were removed under us, and a blank table
          with no explanation is exactly the silence this replaced - so the
          empty state is NOT conditioned on being the first page. */}
      {loaded && entries.length === 0 ? (
        <Typography variant="body2" color="text.secondary" data-testid="audit-empty">
          {t("audit_empty")}
        </Typography>
      ) : null}

      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap"
             useFlexGap data-testid="audit-pager">
        <Button data-testid="audit-prev" disabled={offset === 0}
                onClick={() => page(-1)}>
          {t("prev_page")}
        </Button>
        <Button data-testid="audit-next" disabled={!hasMore}
                onClick={() => page(1)}>
          {t("next_page")}
        </Button>
        <Typography variant="body2" color="text.secondary" data-testid="audit-range">
          {entries.length ? `${offset + 1}-${offset + entries.length}` : ""}
        </Typography>
        {offset !== 0 ? (
          <Typography variant="body2" color="warning.main" data-testid="audit-paused">
            {t("audit_paused")}
          </Typography>
        ) : null}
        {stale ? (
          <Typography variant="body2" color="warning.main" data-testid="audit-stale">
            {t("audit_stale")}
          </Typography>
        ) : null}
      </Stack>
    </Stack>
  );
}
