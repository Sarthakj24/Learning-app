import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, clearToken } from "../api";

export default function Dashboard() {
  const nav = useNavigate();
  const [me, setMe] = useState<any>(null);
  const [locations, setLocations] = useState<any[]>([]);
  const [modules, setModules] = useState<any[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try {
        setMe(await api("/auth/me"));
        setLocations(await api("/api/locations"));
        setModules(await api("/api/modules"));
      } catch (e: any) {
        setError(e.message);
      }
    })();
  }, []);

  function logout() {
    clearToken();
    nav("/login");
  }

  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">
          <span className="brand__mark">W</span>
          <div className="brand__name">WH Now Learn</div>
        </div>
        <nav>
          {["Dashboard", "Content library", "Assign training", "Users & roles", "Skills", "Reports"].map((x, i) => (
            <a key={x} className={i === 0 ? "on" : ""}>{x}</a>
          ))}
        </nav>
      </aside>
      <main className="main">
        <header className="topbar">
          <h2>Dashboard</h2>
          <button className="btn btn--ghost" onClick={logout}>Sign out</button>
        </header>
        {error && <div className="error">{error}</div>}

        <section className="cards">
          <div className="card"><div className="k">Locations</div><div className="v">{locations.length}</div></div>
          <div className="card"><div className="k">Modules available</div><div className="v">{modules.length}</div></div>
          <div className="card"><div className="k">Permissions</div><div className="v">{me?.permissions?.length ?? 0}</div></div>
        </section>

        <section className="panel">
          <h3>Content available to you</h3>
          <p className="muted">Your tenant's modules plus the WH Now global library — scoped by row-level security.</p>
          <table>
            <thead><tr><th>Title</th><th>Scope</th><th>Status</th><th>Language</th></tr></thead>
            <tbody>
              {modules.map((m) => (
                <tr key={m.id}>
                  <td className="nm">{m.title}</td>
                  <td><span className={`tag ${m.scope === "GLOBAL" ? "tag--n" : ""}`}>{m.scope}</span></td>
                  <td>{m.status}</td>
                  <td>{m.language}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        <section className="panel">
          <h3>Locations</h3>
          <ul className="loclist">
            {locations.map((l) => <li key={l.id}>{l.name}</li>)}
          </ul>
        </section>
      </main>
    </div>
  );
}
