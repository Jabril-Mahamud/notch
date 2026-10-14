"use client";

import { useEffect, useState } from "react";

export default function Home() {
  const [visits, setVisits] = useState<number | null>(null);

  // Same-origin /api: Notch routes it to the backend, so no API URL to configure
  useEffect(() => {
    fetch("/api/visits", { method: "POST" })
      .then((r) => r.json())
      .then((d: { visits: number }) => setVisits(d.visits))
      .catch(() => setVisits(-1));
  }, []);

  return (
    <main>
      <h1>__NAME__</h1>
      <p>
        {visits === null ? "Counting..." : visits < 0 ? "Backend unreachable" : `Visit #${visits}, stored in Postgres.`}
      </p>
    </main>
  );
}
