import { create } from 'zustand'

interface DiffState {
  filePath: string
  oldString: string
  newString: string
  setDiff: (filePath: string, oldString: string, newString: string) => void
}

export const useDiffStore = create<DiffState>((set) => ({
  filePath: '',
  oldString: '',
  newString: '',
  setDiff: (filePath, oldString, newString) => set({ filePath, oldString, newString }),
}))
