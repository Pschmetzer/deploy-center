// One refresh at a time, and none lost: a call while one runs does not start a second read in
// parallel, but marks that one more read is due once the running one ends (a setting may have
// changed under it). Any number of such calls give one more read, not one each.

export function coalesce(load: () => Promise<void>): () => Promise<void> {
  let inFlight: Promise<void> | null = null;
  let again = false;
  return () => {
    if (inFlight) { again = true; return inFlight; }
    inFlight = (async () => {
      try {
        do { again = false; await load(); } while (again);
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  };
}
