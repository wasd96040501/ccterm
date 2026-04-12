import SwiftUI
import Observation
import AgentSDK

// This file is kept for PlanReviewViewModel-related types that are still referenced.
// The bulk of plan review logic has moved to SessionHandle + AppViewModel.

// PlanReviewViewModel is no longer needed — plan review state lives on SessionHandle:
//   - activePlanReviewId
//   - planCommentText
//   - pendingCommentSelections
//   - planSearchQuery
// Plan execution logic lives on AppViewModel.executePlanFromReview().
