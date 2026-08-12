export function DashboardStats({ projects, activity }) {
  return (
    <main>
      <h1>Dashboard</h1>
      <p>Projects: {projects.length}</p>
      <p>Activity: {activity.length}</p>
    </main>
  );
}
