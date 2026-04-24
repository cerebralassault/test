    "Description": "Read-only viewer for Arc-enabled SQL Server instances, Arc-connected host machines, performance telemetry, patch history, metrics, resource health, and policy compliance.",
    "Actions": [
        "Microsoft.AzureArcData/sqlServerInstances/read",
        "Microsoft.AzureArcData/sqlServerInstances/databases/read",
        "Microsoft.AzureArcData/sqlServerInstances/availabilityGroups/read",
        "Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action",
        "Microsoft.AzureArcData/locations/operationStatuses/read",
        "Microsoft.AzureArcData/operations/read",

        "Microsoft.HybridCompute/machines/read",
        "Microsoft.HybridCompute/machines/extensions/read",
        "Microsoft.HybridCompute/machines/hybridIdentityMetadata/read",
        "Microsoft.HybridCompute/machines/patchAssessmentResults/read",
        "Microsoft.HybridCompute/machines/patchAssessmentResults/softwarePatches/read",
        "Microsoft.HybridCompute/machines/patchInstallationResults/read",
        "Microsoft.HybridCompute/machines/patchInstallationResults/softwarePatches/read",

        "Microsoft.Insights/metrics/read",
        "Microsoft.Insights/metricDefinitions/read",
        "Microsoft.Insights/diagnosticSettings/read",
        "Microsoft.Insights/diagnosticSettingsCategories/read",
        "Microsoft.Insights/logDefinitions/read",

        "Microsoft.ResourceHealth/availabilityStatuses/read",
        "Microsoft.ResourceHealth/events/read",
        "Microsoft.ResourceHealth/events/impactedResources/read",
        "Microsoft.ResourceHealth/impactedResources/read",

        "Microsoft.ResourceGraph/resources/read",

        "Microsoft.Resources/subscriptions/resourceGroups/read",
        "Microsoft.Resources/subscriptions/resources/read",
        "Microsoft.Resources/tags/read",
        "Microsoft.Resources/subscriptions/operationresults/read",

        "Microsoft.Authorization/policyAssignments/read",
        "Microsoft.Authorization/policyDefinitions/read",
        "Microsoft.Authorization/policySetDefinitions/read",
        "Microsoft.Authorization/permissions/read"
    ],
