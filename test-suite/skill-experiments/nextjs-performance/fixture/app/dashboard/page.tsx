import { DashboardStats } from "../../components/DashboardStats";

async function getProjects() {
  return [{ id: "p1", name: "Alpha" }];
}

async function getActivity() {
  return [{ id: "a1", label: "Created project" }];
}

export default async function DashboardPage() {
  const projects = await getProjects();
  const activity = await getActivity();

  return <DashboardStats projects={projects} activity={activity} />;
}
