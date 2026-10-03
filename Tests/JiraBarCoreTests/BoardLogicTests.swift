import Testing
import Foundation
@testable import JiraBarCore

// Fixtures mirror the structure of two real Jira Server boards: a Kanban board with a real Backlog
// column and a Scrum board (read through the REST API).

let ddsProfile = BoardProfile(
    id: 95, name: "DDS Kanban Board", type: .kanban, projectKey: "DDS",
    columns: [
        BoardColumn(name: "Backlog", statusIds: ["10108"]),
        BoardColumn(name: "To Do", statusIds: ["10004"]),
        BoardColumn(name: "🟠 Working on it", statusIds: ["3"]),
        BoardColumn(name: "🟣 QC Ready", statusIds: ["10013"]),
        BoardColumn(name: "🔵 Testing", statusIds: ["10406"]),
        BoardColumn(name: "🔴 Rejected", statusIds: ["10107"]),
        BoardColumn(name: "🟢 Done", statusIds: ["10003"]),
    ],
    issueTypes: [IssueTypeRef(id: "10200", name: "Task"), IssueTypeRef(id: "10001", name: "Story")],
    storyPointsField: "customfield_10106", sprintField: "customfield_10100"
)

let disProfile = BoardProfile(
    id: 66, name: "DIS Board", type: .scrum, projectKey: "DIS",
    columns: [
        BoardColumn(name: "To Do", statusIds: ["10004", "1", "10103"]),
        BoardColumn(name: "In Progress", statusIds: ["10007", "10000", "10002", "3", "10001", "10006"]),
        BoardColumn(name: "In Review", statusIds: ["10005"]),
        BoardColumn(name: "Blocked", statusIds: ["10102"]),
        BoardColumn(name: "Done", statusIds: ["6", "10003"]),
    ],
    issueTypes: [IssueTypeRef(id: "10200", name: "Task")],
    storyPointsField: "customfield_10106", sprintField: "customfield_10100"
)

// Transitions seen on a real DDS issue sitting in Backlog.
let ddsFromBacklog: [JiraTransition] = [
    JiraTransition(id: "11", name: "To Do", toStatusId: "10004", toStatusName: "To Do"),
    JiraTransition(id: "21", name: "In Progress", toStatusId: "3", toStatusName: "In Progress"),
    JiraTransition(id: "31", name: "Blocked", toStatusId: "10102", toStatusName: "Blocked"),
    JiraTransition(id: "41", name: "Test", toStatusId: "10013", toStatusName: "Test"),
    JiraTransition(id: "51", name: "To Backlog", toStatusId: "10108", toStatusName: "Backlog"),
]

// Transitions seen on a real DIS issue sitting in To Do.
let disFromToDo: [JiraTransition] = [
    JiraTransition(id: "11", name: "To Do", toStatusId: "10004", toStatusName: "To Do"),
    JiraTransition(id: "21", name: "In Progress", toStatusId: "3", toStatusName: "In Progress"),
    JiraTransition(id: "31", name: "Done", toStatusId: "10003", toStatusName: "Done"),
    JiraTransition(id: "41", name: "Blocked", toStatusId: "10102", toStatusName: "Blocked"),
    JiraTransition(id: "51", name: "Test", toStatusId: "10013", toStatusName: "Test"),
]

func ddsIssue(status: String) -> BoardIssue {
    BoardIssue(key: "DDS-1", summary: "x", statusId: status, statusName: "", issueType: "Task")
}

func disIssue(status: String, sprint: Int?) -> BoardIssue {
    BoardIssue(key: "DIS-1", summary: "x", statusId: status, statusName: "", issueType: "Task", activeSprintId: sprint)
}

@Suite struct KanbanMoveTests {
    let cols = BoardLogic.columns(for: ddsProfile)

    @Test func kanbanHasNoVirtualBacklog() {
        #expect(cols.count == 7)
        #expect(cols[0].name == "Backlog")
        #expect(cols.allSatisfy { !$0.isBacklog })
    }

    @Test func rightFromBacklogGoesToToDo() {
        let plan = BoardLogic.plan(for: ddsIssue(status: "10108"), columns: cols, type: .kanban,
                                   transitions: ddsFromBacklog, direction: 1, jump: false, hasActiveSprint: false)
        #expect(plan == .transition(ddsFromBacklog[0], toColumn: 1))
    }

    @Test func jumpRightStopsAtLastReachableColumn() {
        // Testing / Rejected / Done have no transition from Backlog, QC Ready ("Test") is the furthest.
        let plan = BoardLogic.plan(for: ddsIssue(status: "10108"), columns: cols, type: .kanban,
                                   transitions: ddsFromBacklog, direction: 1, jump: true, hasActiveSprint: false)
        #expect(plan == .transition(ddsFromBacklog[3], toColumn: 3))
    }

    @Test func stepSkipsUnreachableColumns() {
        // From QC Ready only "Done" is reachable to the right (Testing/Rejected aren't offered).
        let fromQC = [JiraTransition(id: "9", name: "Done", toStatusId: "10003", toStatusName: "Done")]
        let plan = BoardLogic.plan(for: ddsIssue(status: "10013"), columns: cols, type: .kanban,
                                   transitions: fromQC, direction: 1, jump: false, hasActiveSprint: false)
        #expect(plan == .transition(fromQC[0], toColumn: 6))
    }

    @Test func leftFromFirstColumnDoesNothing() {
        let plan = BoardLogic.plan(for: ddsIssue(status: "10108"), columns: cols, type: .kanban,
                                   transitions: ddsFromBacklog, direction: -1, jump: false, hasActiveSprint: false)
        #expect(plan == nil)
    }

    @Test func leftFromToDoGoesBackToBacklog() {
        let fromToDo = [JiraTransition(id: "7", name: "To Backlog", toStatusId: "10108", toStatusName: "Backlog")]
        let plan = BoardLogic.plan(for: ddsIssue(status: "10004"), columns: cols, type: .kanban,
                                   transitions: fromToDo, direction: -1, jump: false, hasActiveSprint: false)
        #expect(plan == .transition(fromToDo[0], toColumn: 0))
    }

    @Test func unmappedStatusCannotMove() {
        let plan = BoardLogic.plan(for: ddsIssue(status: "99999"), columns: cols, type: .kanban,
                                   transitions: ddsFromBacklog, direction: 1, jump: false, hasActiveSprint: false)
        #expect(plan == nil)
    }
}

@Suite struct ScrumMoveTests {
    let cols = BoardLogic.columns(for: disProfile)

    @Test func scrumGetsVirtualBacklogFirst() {
        #expect(cols.count == 6)
        #expect(cols[0].isBacklog && cols[0].name == "Backlog")
        #expect(cols[1].name == "To Do")
    }

    @Test func issueOutsideSprintLivesInBacklog() {
        let i = disIssue(status: "10004", sprint: nil)
        #expect(BoardLogic.columnIndex(of: i, in: cols, type: .scrum) == 0)
        let j = disIssue(status: "10004", sprint: 266)
        #expect(BoardLogic.columnIndex(of: j, in: cols, type: .scrum) == 1)
    }

    @Test func rightFromBacklogAddsToActiveSprint() {
        let plan = BoardLogic.plan(for: disIssue(status: "10004", sprint: nil), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: 1, jump: false, hasActiveSprint: true)
        #expect(plan == .addToSprint(toColumn: 1, then: nil))
    }

    @Test func rightFromBacklogWithoutActiveSprintDoesNothing() {
        let plan = BoardLogic.plan(for: disIssue(status: "10004", sprint: nil), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: 1, jump: false, hasActiveSprint: false)
        #expect(plan == nil)
    }

    @Test func leftFromToDoRemovesFromSprint() {
        let plan = BoardLogic.plan(for: disIssue(status: "10004", sprint: 266), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: -1, jump: false, hasActiveSprint: true)
        #expect(plan == .removeFromSprint(toColumn: 0))
    }

    @Test func rightFromToDoStartsWork() {
        let plan = BoardLogic.plan(for: disIssue(status: "10004", sprint: 266), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: 1, jump: false, hasActiveSprint: true)
        #expect(plan == .transition(disFromToDo[1], toColumn: 2))
    }

    @Test func carriedOverInProgressTaskKeepsItsColumnWhenJoiningSprint() {
        let plan = BoardLogic.plan(for: disIssue(status: "3", sprint: nil), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: 1, jump: false, hasActiveSprint: true)
        #expect(plan == .addToSprint(toColumn: 2, then: nil))
    }

    @Test func jumpRightGoesToDone() {
        let plan = BoardLogic.plan(for: disIssue(status: "10004", sprint: 266), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: 1, jump: true, hasActiveSprint: true)
        #expect(plan == .transition(disFromToDo[2], toColumn: 5))
    }

    @Test func jumpFromBacklogIntoSprintThenTransition() {
        let plan = BoardLogic.plan(for: disIssue(status: "10004", sprint: nil), columns: cols, type: .scrum,
                                   transitions: disFromToDo, direction: 1, jump: true, hasActiveSprint: true)
        #expect(plan == .addToSprint(toColumn: 5, then: disFromToDo[2]))
    }
}

@Suite struct SprintAndJQLTests {
    @Test func parsesLegacyServerSprintString() {
        let raw = "com.atlassian.greenhopper.service.sprint.Sprint@323c8cc3[activatedDate=2026-09-30T14:14:45.975Z,autoStartStop=false,completeDate=<null>,endDate=2026-10-10T06:30:00.000Z,goal=,id=266,incompleteIssuesDestinationId=<null>,name=H2 1405 - S02 - DIS,rapidViewId=66,sequence=266,startDate=2026-10-03T06:30:00.000Z,state=ACTIVE,synced=false]"
        let sprints = SprintParser.parse(.array([.string(raw)]))
        #expect(sprints.count == 1)
        #expect(sprints[0].id == 266)
        #expect(sprints[0].name == "H2 1405 - S02 - DIS")
        #expect(sprints[0].isActive)
    }

    @Test func parsesObjectSprint() {
        let v: JSONValue = .array([.object(["id": .number(7), "name": .string("S7"), "state": .string("closed")])])
        let s = SprintParser.parse(v)
        #expect(s == [SprintRef(id: 7, name: "S7", state: "closed")])
        #expect(!s[0].isActive)
    }

    @Test func emptyOrNullSprintFieldMeansNoSprint() {
        #expect(SprintParser.parse(nil).isEmpty)
        #expect(SprintParser.parse(.null).isEmpty)
        #expect(SprintParser.parse(.array([])).isEmpty)
    }

    @Test func jqlVariants() {
        #expect(BoardLogic.jql(type: .scrum, scope: .mine).contains("sprint in openSprints()"))
        #expect(BoardLogic.jql(type: .scrum, scope: .all) == "sprint in openSprints()")
        #expect(BoardLogic.jql(type: .kanban, scope: .mine).contains("currentUser()"))
        #expect(BoardLogic.jql(type: .kanban, scope: .mine).contains("updated >= -3d"))
        // never rely on resolution: DIS reaches Done without setting one
        for t in [BoardType.scrum, .kanban] {
            for s in BoardScope.allCases { #expect(!BoardLogic.jql(type: t, scope: s).contains("resolution")) }
        }
    }

    @Test func parsesBoardIssueFromRealShape() throws {
        let json = """
        {"key":"DIS-780","fields":{"summary":"Fix it","status":{"id":"10004","name":"To Do"},
        "issuetype":{"name":"Task"},"assignee":{"displayName":"Me"},"customfield_10106":3.0,
        "customfield_10100":["com.atlassian.greenhopper.service.sprint.Sprint@1[id=266,name=S02,rapidViewId=66,state=ACTIVE]"]}}
        """
        let v = try JSONValue.parse(Data(json.utf8))
        let issue = try #require(JiraClient.parseIssue(v, profile: disProfile))
        #expect(issue.key == "DIS-780")
        #expect(issue.storyPoints == 3)
        #expect(issue.activeSprintId == 266)
        #expect(issue.statusId == "10004")
    }
}
