import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, clearToken } from "../api";

const TABS = [
  "Dashboard",
  "Content library",
  "Assign training",
  "Users & roles",
  "Skills",
  "Reports",
] as const;
type Tab = (typeof TABS)[number];

export default function Dashboard() {
  const nav = useNavigate();
  const [tab, setTab] = useState<Tab>("Dashboard");
  const [me, setMe] = useState<any>(null);
  const [locations, setLocations] = useState<any[]>([]);
  const [modules, setModules] = useState<any[]>([]);
  const [users, setUsers] = useState<any[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const [meData, locsData, modsData] = await Promise.all([
          api("/auth/me"),
          api("/api/locations"),
          api("/api/modules"),
        ]);
        setMe(meData);
        setLocations(locsData);
        setModules(modsData);
      } catch (e: any) {
        setError(e.message);
      }
    })();
  }, []);

  async function loadUsers() {
    if (users.length > 0) return;
    try {
      setUsers(await api("/api/users"));
    } catch (e: any) {
      setError(e.message);
    }
  }

  function handleTab(t: Tab) {
    setTab(t);
    if (t === "Users & roles") loadUsers();
  }

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
          {TABS.map((t) => (
            <a
              key={t}
              className={t === tab ? "on" : ""}
              onClick={() => handleTab(t)}
            >
              {t}
            </a>
          ))}
        </nav>
      </aside>
      <main className="main">
        <header className="topbar">
          <h2>{tab}</h2>
          <button className="btn btn--ghost" onClick={logout}>
            Sign out
          </button>
        </header>

        {error && <div className="error">{error}</div>}

        {tab === "Dashboard" && (
          <>
            <section className="cards">
              <div className="card">
                <div className="k">Locations</div>
                <div className="v">{locations.length}</div>
              </div>
              <div className="card">
                <div className="k">Modules available</div>
                <div className="v">{modules.length}</div>
              </div>
              <div className="card">
                <div className="k">My permissions</div>
                <div className="v">{me?.permissions?.length ?? 0}</div>
              </div>
            </section>

            <section className="panel">
              <h3>Welcome back{me?.profile?.full_name ? `, ${me.profile.full_name}` : ""}</h3>
              <p className="muted">
                {me?.isSuperAdmin ? "Super Admin" : "Tenant user"} &nbsp;·&nbsp;{" "}
                {me?.permissions?.length ?? 0} permissions
              </p>
            </section>

            <section className="panel">
              <h3>Locations</h3>
              <ul className="loclist">
                {locations.map((l) => (
                  <li key={l.id}>{l.name}</li>
                ))}
              </ul>
            </section>
          </>
        )}

        {tab === "Content library" && (
          <section className="panel">
            <h3>Modules</h3>
            <p className="muted">
              Your tenant's modules plus the WH Now global library — scoped by row-level security.
            </p>
            <table>
              <thead>
                <tr>
                  <th>Title</th>
                  <th>Scope</th>
                  <th>Status</th>
                  <th>Language</th>
                </tr>
              </thead>
              <tbody>
                {modules.map((m) => (
                  <tr key={m.id}>
                    <td className="nm">{m.title}</td>
                    <td>
                      <span className={`tag ${m.scope === "GLOBAL" ? "tag--n" : ""}`}>
                        {m.scope}
                      </span>
                    </td>
                    <td>{m.status}</td>
                    <td>{m.language ?? "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        )}

        {tab === "Users & roles" && (
          <section className="panel">
            <h3>Users</h3>
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                  <th>Role</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {users.map((u) => (
                  <tr key={u.id}>
                    <td className="nm">{u.full_name}</td>
                    <td>{u.email}</td>
                    <td>
                      {u.user_roles?.map((r: any) => r.roles?.name).join(", ") ?? "—"}
                    </td>
                    <td>{u.status}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        )}

        {(tab === "Assign training" || tab === "Skills" || tab === "Reports") && (
          <section className="panel">
            <h3>{tab}</h3>
            <p className="muted">Coming soon — this feature is on the roadmap.</p>
          </section>
        )}
      </main>
    </div>
  );
}
