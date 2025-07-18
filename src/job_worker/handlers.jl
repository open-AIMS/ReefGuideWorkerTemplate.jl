"""
This is the file where handlers, input and output payloads are registered to
handle jobs for this worker.
"""

# ================
# Type Definitions
# ================

"""
Represents a job that needs to be processed
"""
struct Job
    "Job ID in the DB"
    id::Int64
    "What type of Job - strict set of enums"
    type::String
    "The payload defining the job parameters - should correspond to input payload type registered in Jobs.jl"
    input_payload::Any
end

"""
Represents an assignment for a job
"""
struct JobAssignment
    "ID of the assignment in the DB"
    id::Int64
    "ID of the tasked job"
    job_id::Int64
    "Path to where the data can be stored (in s3)"
    storage_uri::String
end

"""
Context provided to job handlers with all necessary information
"""
struct JobContext
    "Worker configuration"
    config::WorkerConfig
    "The job to be processed"
    job::Job
    "The job assignment details"
    assignment::JobAssignment
    "The API client for making HTTP requests"
    http_client::AuthApiClient
    "Storage client e.g. s3"
    storage_client::StorageClient
    "Task metadata"
    task_metadata::Any
    "AWS region for s3 storage"
    aws_region::String
    "S3 endpoint"
    s3_endpoint::OptionalValue{String}

    "Constructor that takes all fields"
    function JobContext(;
        config::WorkerConfig,
        job::Job,
        assignment::JobAssignment,
        http_client::AuthApiClient,
        storage_client::StorageClient,
        task_metadata::Any
    )
        return new(
            config,
            job,
            assignment,
            http_client,
            storage_client,
            task_metadata
        )
    end
end

"""
Enum for job types matching the API definition
"""
@enum JobType begin
    # Here is where you would add job types you want to handle
    TEST
end

symbol_to_job_type = Dict(zip(Symbol.(instances(JobType)), instances(JobType)))

"""
Enum for storage schemes matching the API definition
"""
@enum StorageScheme begin
    S3
    # Add more storage schemes as needed
end

"""
Abstract type for job input payloads
All concrete job input types should inherit from this
"""
abstract type AbstractJobInput end

"""
Abstract type for job output payloads
All concrete job output types should inherit from this
"""
abstract type AbstractJobOutput end

"""
Abstract type for job handler implementations
All concrete job handlers should inherit from this
"""
abstract type AbstractJobHandler end

"""
A context object passed through to a job handler
"""
struct HandlerContext
    "The path to the s3 storage location permitted for writing"
    storage_uri::String
    aws_region::String
    s3_endpoint::OptionalValue{String}

    function HandlerContext(;
        storage_uri::String, aws_region::String="ap-southeast-2",
        s3_endpoint::OptionalValue{String}=nothing
    )
        return new(storage_uri, aws_region, s3_endpoint)
    end
end

"""
Registry mapping job types to handlers, input/output types, and validators
"""
struct JobRegistry
    handlers::Dict{JobType,AbstractJobHandler}
    input_types::Dict{JobType,Type{<:AbstractJobInput}}
    output_types::Dict{JobType,Type{<:AbstractJobOutput}}

    function JobRegistry()
        return new(
            Dict{JobType,AbstractJobHandler}(),
            Dict{JobType,Type{<:AbstractJobInput}}(),
            Dict{JobType,Type{<:AbstractJobOutput}}()
        )
    end
end

# Global registry instance
const JOB_REGISTRY = JobRegistry()

# ======================
# Registration functions
# ======================

"""
Register a job handler for a specific job type
"""
function register_job_handler!(
    job_type::JobType,
    handler::AbstractJobHandler,
    input_type::Type{<:AbstractJobInput},
    output_type::Type{<:AbstractJobOutput}
)
    JOB_REGISTRY.handlers[job_type] = handler
    JOB_REGISTRY.input_types[job_type] = input_type
    JOB_REGISTRY.output_types[job_type] = output_type

    @debug "Registered handler for job type: $job_type"
    return nothing
end

"""
Get the appropriate handler for a job type
"""
function get_job_handler(job_type::JobType)::AbstractJobHandler
    if !haskey(JOB_REGISTRY.handlers, job_type)
        error("No handler registered for job type: $job_type")
    end
    return JOB_REGISTRY.handlers[job_type]
end

#
# Validation functions
#

"""
Parse and validate a job input payload
"""
function validate_job_input(job_type::JobType, raw_payload::Any)
    if !haskey(JOB_REGISTRY.input_types, job_type)
        error("No input type registered for job type: $job_type")
    end

    input_type = JOB_REGISTRY.input_types[job_type]

    try
        # Parse the raw JSON payload into the appropriate type
        return JSON3.read(JSON3.write(raw_payload), input_type)
    catch e
        @error "Input validation failed for job type $job_type" exception = (
            e, catch_backtrace()
        )
        error("Invalid input payload for job type: $job_type")
    end
end

"""
Validate a job output payload
"""
function validate_job_output(job_type::JobType, output::AbstractJobOutput)
    if !haskey(JOB_REGISTRY.output_types, job_type)
        error("No output type registered for job type: $job_type")
    end

    expected_type = JOB_REGISTRY.output_types[job_type]

    if !isa(output, expected_type)
        error("Output payload is not of the correct type for job type: $job_type")
    end

    return output
end

#
# Job processing
#

"""
Process a job using the appropriate handler
"""
function process_job(
    job_type::JobType, input_payload::Any, context::JobContext
)::AbstractJobOutput
    # Get the registered handler
    handler = get_job_handler(job_type)

    # Validate and convert input payload
    typed_input = validate_job_input(job_type, input_payload)

    # Process the job
    @debug "Processing job of type: $job_type"
    output = handle_job(handler, typed_input, context)

    # Validate output
    validate_job_output(job_type, output)

    return output
end

#
# ============================================
# TEST - this is an example set of job methods
# ============================================
#

"""
Input payload for TEST job
"""
struct TestInput <: AbstractJobInput
    id::Int64
end

"""
Output payload for TEST job
"""
struct TestOutput <: AbstractJobOutput
end

"""
Handler for TEST jobs
"""
struct TestHandler <: AbstractJobHandler end

"""
Process a TEST job
"""
function handle_job(
    ::TestHandler, input::TestInput, context::JobContext
)::TestOutput
    @debug "Processing test job with id: $(input.id)"

    # Simulate processing time
    sleep(10)

    @debug "Finished test job with id: $(input.id)"
    @debug "Could write something to $(context.assignment.storage_uri) if desired."

    # This is where the actual job processing would happen
    # For now, we just return a dummy output
    return TestOutput()
end

#
# ====
# INIT
# ====
#

#
# Register the job types when the module loads
#
function __init__()
    # Register the TEST job handler
    register_job_handler!(
        TEST,
        TestHandler(),
        TestInput,
        TestOutput
    )

    # initialise more methods here as above

    @debug "Jobs module initialized with handlers"
end
