"use server";

export async function updateProject(projectId: string, name: string) {
  await saveProject(projectId, { name });
}

async function saveProject(projectId: string, patch: { name: string }) {
  return { projectId, ...patch };
}
