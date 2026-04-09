import { create } from 'zustand'

export interface PlanCommentDTO {
  id: string
  text: string
  isInline: boolean
  startOffset?: number
  endOffset?: number
  selectedText?: string
  createdAt: string
}

interface PlanData {
  markdown: string
  comments: PlanCommentDTO[]
}

interface PlanFullScreenState {
  plans: Record<string, PlanData>
  currentKey: string

  setPlan: (key: string, markdown: string) => void
  setComments: (key: string, comments: PlanCommentDTO[]) => void
  switchPlan: (key: string) => void
  clearPlan: (key: string) => void
}

export const usePlanFullScreenStore = create<PlanFullScreenState>((set) => ({
  plans: {},
  currentKey: '',

  setPlan: (key, markdown) =>
    set((s) => ({
      plans: { ...s.plans, [key]: { markdown, comments: s.plans[key]?.comments ?? [] } },
    })),

  setComments: (key, comments) =>
    set((s) => ({
      plans: {
        ...s.plans,
        [key]: { markdown: s.plans[key]?.markdown ?? '', comments },
      },
    })),

  switchPlan: (key) => set({ currentKey: key }),

  clearPlan: (key) =>
    set((s) => {
      const { [key]: _, ...rest } = s.plans
      return { plans: rest }
    }),
}))
