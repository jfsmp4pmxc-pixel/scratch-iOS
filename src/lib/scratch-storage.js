// src/lib/scratch-storage.js
import { Filesystem, Directory } from '@capacitor/filesystem';

const PROJECTS_DIR = 'scratch_projects';

// Đảm bảo thư mục tồn tại
async function ensureProjectsDir() {
    try {
        await Filesystem.mkdir({
            path: PROJECTS_DIR,
            directory: Directory.Documents,
            recursive: true
        });
    } catch (e) { /* đã tồn tại */ }
}

// ArrayBuffer -> base64 (chia chunk để tránh stack overflow với file lớn)
function arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
}

function base64ToArrayBuffer(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
}

// Lưu project thành .sb3
export async function saveProject(vm, projectName) {
    await ensureProjectsDir();
    const blob = await vm.saveProjectSb3();
    const arrayBuffer = await blob.arrayBuffer();
    const base64 = arrayBufferToBase64(arrayBuffer);

    await Filesystem.writeFile({
        path: `${PROJECTS_DIR}/${projectName}.sb3`,
        data: base64,
        directory: Directory.Documents,
        recursive: true
    });
    return `${projectName}.sb3`;
}

// Liệt kê project
export async function listProjects() {
    await ensureProjectsDir();
    try {
        const result = await Filesystem.readdir({
            path: PROJECTS_DIR,
            directory: Directory.Documents
        });
        return result.files
            .filter(f => f.name.endsWith('.sb3'))
            .map(f => ({
                name: f.name,
                displayName: f.name.replace(/\.sb3$/, ''),
                mtime: f.mtime || 0
            }))
            .sort((a, b) => b.mtime - a.mtime);
    } catch (e) {
        return [];
    }
}

// Load project
export async function loadProject(vm, fileName) {
    const fileResult = await Filesystem.readFile({
        path: `${PROJECTS_DIR}/${fileName}`,
        directory: Directory.Documents
    });
    // readFile không set encoding -> trả về base64
    const arrayBuffer = base64ToArrayBuffer(fileResult.data);
    await vm.loadProject(arrayBuffer);
}

// Xoá
export async function deleteProject(fileName) {
    await Filesystem.deleteFile({
        path: `${PROJECTS_DIR}/${fileName}`,
        directory: Directory.Documents
    });
}