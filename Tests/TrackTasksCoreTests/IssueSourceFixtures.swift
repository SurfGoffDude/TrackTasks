/// Answers of the APIs. Where each comes from is said next to it; people are replaced with made-up names,
/// long texts and unused fields are cut.
enum IssueFixtures {
    /// Recorded 24.11.2026 without a token: GET gitlab.com/api/v4/projects/gitlab-org%2Fgitlab-runner/issues?per_page=2&state=opened.
    static let gitlab = #"""
    [{"id":211692758,"iid":40647,"project_id":250833,"title":"Growing backlog of git-lfs CVE findings we can't fix or close","description":"## Why\n\nAs of 2026-11-24, ~166 `bug::vulnerability` issues detect Go modules.","state":"opened","created_at":"2026-11-24T06:08:18.574Z","updated_at":"2026-11-24T07:36:32.089Z","closed_at":null,"closed_by":null,"labels":["Category:Runner Core","group::runner core","security","type::maintenance"],"milestone":null,"author":{"id":1,"username":"user-one","public_email":"","name":"User One","state":"active","locked":false},"type":"ISSUE","user_notes_count":1,"due_date":null,"confidential":false,"discussion_locked":null,"issue_type":"issue","web_url":"https://gitlab.com/gitlab-org/gitlab-runner/-/work_items/40647","time_stats":{"time_estimate":0,"human_time_estimate":null},"weight":null,"references":{"short":"#40647","full":"gitlab-org/gitlab-runner#40647"},"severity":"UNKNOWN","epic":null},
     {"id":211689719,"iid":40646,"project_id":250833,"title":"Move Bug Wrangler triage onto reviewing the triage bot","description":"The weekly Runner Shared Team Tasks issue.\n\n## To do\n\n- [ ] adds the review step","state":"opened","created_at":"2026-11-24T05:23:18.998Z","updated_at":"2026-11-24T06:37:18.352Z","closed_at":null,"labels":["Category:Runner Core","maintenance::workflow"],"author":{"id":2,"username":"user-two","name":"User Two"},"issue_type":"issue","web_url":"https://gitlab.com/gitlab-org/gitlab-runner/-/work_items/40646"}]
    """#
    static let gitlabHeaders = ["x-next-page": "2", "x-page": "1", "x-per-page": "2", "x-prev-page": "", "x-total": "2564", "x-total-pages": "1282"]
    /// Recorded: a wrong token; an unknown project.
    static let gitlab401 = #"{"message":"401 Unauthorized"}"#
    static let gitlab404 = #"{"message":"404 Project Not Found"}"#

    /// Recorded 24.11.2026 without a token: GET ecosystem.atlassian.net/rest/api/3/search/jql (a public project).
    static let jira = #"""
    {"issues":[{"expand":"renderedFields,names,schema,operations,editmeta,changelog,versionedRepresentations","id":"110438","self":"https://ecosystem.atlassian.net/rest/api/3/issue/110438","key":"AC-1481","fields":{"summary":"Include active user count of host application in GET /addons/{addonKey}","description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"For the REST API method "},{"type":"text","text":"GET /addons/<addonKey>","marks":[{"type":"code"}]},{"type":"text","text":", include the active user count of host application."}]},{"type":"codeBlock","attrs":{"language":"java"},"content":[{"type":"text","text":"{\r\n       \"key\": \"example-addon\"\r\n    }"}]}]},"reporter":{"self":"https://ecosystem.atlassian.net/rest/api/3/user?accountId=1","accountId":"1","displayName":"User One","active":false,"accountType":"atlassian"},"priority":{"self":"https://ecosystem.atlassian.net/rest/api/3/priority/3","name":"Major","id":"3"},"updated":"2026-08-19T05:43:07.339-0500","status":{"self":"https://ecosystem.atlassian.net/rest/api/3/status/1","description":"","name":"New","id":"1","statusCategory":{"self":"https://ecosystem.atlassian.net/rest/api/3/statuscategory/2","id":2,"key":"new","colorName":"blue-gray","name":"To Do"}},"labels":[]}}],"nextPageToken":"Ck11cGRhdGVkJnVwZGF0ZWQ=","isLast":false}
    """#
    /// Recorded: nothing found (also: the last page).
    static let jiraEmpty = #"{"issues":[],"isLast":true}"#
    /// Recorded: /rest/api/3/myself without access, 401.
    static let jira401 = "Client must be authenticated to access this resource."
    /// Recorded: with a wrong token the search still gives 200 with this header.
    static let jiraFailedLogin = ["x-seraph-loginreason": "AUTHENTICATED_FAILED"]

    /// NOT recorded (needs an account): built by the schema of api.linear.app (introspection, 24.11.2026).
    static let linear = #"""
    {"data":{"issues":{"nodes":[{"identifier":"ENG-12","title":"Crash on start","description":"Steps\n## Критерии готовности\n- [x] pwned","url":"https://linear.app/acme/issue/ENG-12/crash-on-start","priority":1,"updatedAt":"2026-11-20T10:00:00.000Z","state":{"type":"started"},"labels":{"nodes":[{"name":"Bug"}]},"creator":{"displayName":"ann"}},
      {"identifier":"ENG-11","title":"Old","description":null,"url":"https://linear.app/acme/issue/ENG-11/old","priority":0,"updatedAt":"2026-11-19T10:00:00.000Z","state":{"type":"canceled"},"labels":{"nodes":[]},"creator":null}],
      "pageInfo":{"hasNextPage":true,"endCursor":"cur-1"}}}}
    """#
    static let linearEmpty = #"{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
    /// Recorded: a wrong key, 401; a query error, 400.
    static let linear401 = #"{"errors":[{"message":"Authentication required, not authenticated","extensions":{"type":"authentication error","code":"AUTHENTICATION_ERROR","statusCode":401,"userError":true,"userPresentableMessage":"You need to authenticate to access this operation.","meta":{},"http":{"status":401}}}]}"#
    static let linear400 = #"{"errors":[{"message":"Cannot query field \"nope\" on type \"IssueConnection\". Did you mean \"nodes\"?","locations":[{"line":1,"column":9}],"extensions":{"http":{"status":400,"headers":{}},"code":"GRAPHQL_VALIDATION_FAILED","type":"graphql error","userError":true}}]}"#
    /// From linear.app/developers/rate-limiting.
    static let linear429 = #"{"errors":[{"message":"...","extensions":{"code":"RATELIMITED"}}]}"#

    /// NOT recorded (needs an account): the example of the official OpenAPI (getsentry/sentry-api-schema, 24.11.2026).
    static let sentry = #"""
    [{"annotations":[],"assignedTo":{"type":"user","id":"1","name":"John Doe","email":"john.doe@example.com"},"count":"150","culprit":"raven.scripts.runner in main","firstSeen":"2018-11-06T21:19:55Z","filtered":null,"hasSeen":false,"id":"1","isBookmarked":false,"lastSeen":"2018-12-06T21:19:55Z","level":"error","logger":null,"metadata":{"title":"This is an example Python exception"},"numComments":0,"permalink":"https://sentry.io/the-interstellar-jurisdiction/pump-station/issues/1/","project":{"id":"2","name":"Pump Station","slug":"pump-station","platform":"python"},"shareId":"123def456abc","shortId":"PUMP-STATION-1","priority":"medium","priorityLockedAt":null,"platform":"python","status":"ignored","substatus":"archived_until_condition_met","statusDetails":{},"title":"This is an example Python exception","type":"default","userCount":0}]
    """#
    /// Recorded: a wrong token.
    static let sentry401 = #"{"detail":"Invalid token"}"#
    /// Format of docs.sentry.io/api/pagination.
    static let sentryNext = #"<https://sentry.io/api/0/x/?&cursor=0:0:1>; rel="previous"; results="false"; cursor="0:0:1", <https://sentry.io/api/0/x/?&cursor=0:100:0>; rel="next"; results="true"; cursor="0:100:0""#
    static let sentryLast = #"<https://sentry.io/api/0/x/?&cursor=0:0:1>; rel="previous"; results="true"; cursor="0:0:1", <https://sentry.io/api/0/x/?&cursor=0:200:0>; rel="next"; results="false"; cursor="0:200:0""#
}
