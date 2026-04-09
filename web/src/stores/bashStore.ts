import { create } from 'zustand'

interface BashState {
  command: string
  setCommand: (command: string) => void
}

export const useBashStore = create<BashState>((set) => ({
  command: '',
  setCommand: (command) => set({ command }),
}))
