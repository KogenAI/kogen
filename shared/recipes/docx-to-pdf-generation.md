# Recipe: DOCX Template to PDF Generation in Phoenix/Elixir

## Problem

Need to generate personalized PDF documents (contracts, offers, invoices) from DOCX templates with variable substitution, without heavyweight dependencies or external services.

## Solution

Use DOCX templates with `{{variable_name}}` placeholders, LibreOffice for DOCX→PDF conversion, S3/object storage for persistence, and integrate with Phoenix message/media system for delivery.

## Implementation

### Step 1: Create DOCX Template

Create a template in Microsoft Word or LibreOffice with placeholder variables:

```
Employment Agreement

This agreement is between {{company_name}} and {{employee_name}}.

Position: {{job_title}}
Start Date: {{start_date}}
Salary: CHF {{salary}}

Signed by: {{recruiter_name}}, {{recruiter_position}}
Contact: {{recruiter_phone}}
```

Save as `.docx` and store in `priv/documents/` directory.

### Step 2: Document Processing Module

```elixir
defmodule MyApp.Documents.Processor do
  @moduledoc """
  Processes DOCX templates with variable substitution and converts to PDF.
  """

  @doc """
  Replace template variables in DOCX file with actual values.
  Returns path to modified DOCX file.
  """
  def replace_variables(template_path, variables) when is_map(variables) do
    # DOCX files are ZIP archives containing XML
    # Extract, modify XML, repackage

    temp_dir = System.tmp_dir!()
    extract_dir = Path.join(temp_dir, "docx_extract_#{:rand.uniform(100_000)}")

    # Extract DOCX (it's a ZIP)
    :zip.unzip(
      String.to_charlist(template_path),
      cwd: String.to_charlist(extract_dir)
    )

    # Find and modify document.xml
    doc_xml_path = Path.join([extract_dir, "word", "document.xml"])
    {:ok, content} = File.read(doc_xml_path)

    # Replace variables
    modified_content = Enum.reduce(variables, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)

    File.write!(doc_xml_path, modified_content)

    # Repackage as DOCX
    output_path = Path.join(temp_dir, "output_#{:rand.uniform(100_000)}.docx")

    # Get all files from extract_dir
    files = list_files_recursive(extract_dir)

    :zip.create(
      String.to_charlist(output_path),
      files,
      cwd: String.to_charlist(extract_dir)
    )

    output_path
  end

  @doc """
  Convert DOCX to PDF using LibreOffice.
  Returns path to generated PDF.
  """
  def convert_to_pdf(docx_path) do
    output_dir = System.tmp_dir!()

    # Use LibreOffice in headless mode for conversion
    {_output, 0} = System.cmd(
      "libreoffice",
      [
        "--headless",
        "--convert-to", "pdf",
        "--outdir", output_dir,
        docx_path
      ],
      stderr_to_stdout: true
    )

    # LibreOffice creates PDF with same basename as input
    basename = Path.basename(docx_path, ".docx")
    Path.join(output_dir, "#{basename}.pdf")
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.flat_map(fn path ->
      if File.dir?(path) do
        list_files_recursive(path)
      else
        [String.to_charlist(Path.relative_to(path, dir))]
      end
    end)
  end
end
```

### Step 3: Storage Integration

```elixir
defmodule MyApp.Documents.Storage do
  @moduledoc """
  Upload/download documents to S3 or Tigris object storage.
  """

  @doc """
  Upload file to object storage.
  """
  def upload_file(upload_id, binary_content, content_type) do
    # Use your S3/Tigris client
    ExAws.S3.put_object(
      bucket(),
      upload_id,
      binary_content,
      content_type: content_type
    )
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Download file from object storage.
  """
  def download_file(upload_id) do
    ExAws.S3.get_object(bucket(), upload_id)
    |> ExAws.request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bucket, do: Application.fetch_env!(:my_app, :storage_bucket)
end
```

### Step 4: Template Management with Fallback

```elixir
defmodule MyApp.OfferWorkflow do
  @doc """
  Generate contract PDF from template.
  Uses company template if available, falls back to default.
  """
  def generate_contract_pdf(offer, job_application) do
    company_id = job_application.job_posting.company_id
    template_upload_id = get_template_upload_id(company_id)

    with {:ok, doc_path} <- download_template(template_upload_id),
         doc_path <- Documents.Processor.replace_variables(doc_path, offer.variables),
         pdf_path <- Documents.Processor.convert_to_pdf(doc_path),
         {:ok, pdf_binary} <- File.read(pdf_path) do
      filename = generate_filename(job_application)
      {:ok, pdf_binary, filename}
    end
  end

  defp get_template_upload_id(company_id) do
    case CompanyTemplates.get_active_template(company_id) do
      %{media_asset: %{upload_id: upload_id}} when is_binary(upload_id) ->
        upload_id
      _template ->
        get_or_upload_default_template()
    end
  end

  defp get_or_upload_default_template do
    # Cache default template upload_id in application env
    case Application.get_env(:my_app, :default_template_id) do
      nil -> upload_default_template()
      upload_id -> upload_id
    end
  end

  defp upload_default_template do
    template_path = Path.join([
      :code.priv_dir(:my_app),
      "documents",
      "default_template.docx"
    ])

    upload_id = Ecto.UUID.generate()

    with {:ok, content} <- File.read(template_path),
         :ok <- Documents.Storage.upload_file(
           upload_id,
           content,
           "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
         ) do
      # Cache in application env to avoid repeated uploads
      Application.put_env(:my_app, :default_template_id, upload_id)
      upload_id
    else
      {:error, reason} ->
        raise "Failed to upload default template: #{inspect(reason)}"
    end
  end

  defp download_template(upload_id) do
    temp_dir = System.tmp_dir!()
    local_path = Path.join(temp_dir, "template_#{upload_id}.docx")

    with {:ok, content} <- Documents.Storage.download_file(upload_id),
         :ok <- File.write(local_path, content) do
      {:ok, local_path}
    end
  end

  defp generate_filename(job_application) do
    user = job_application.user
    date = Date.to_string(Date.utc_today())
    "contract_#{user.first_name}_#{user.last_name}_#{date}.pdf"
  end
end
```

### Step 5: Integration with Message System

```elixir
defmodule MyApp.OfferFormComponent do
  use MyAppWeb, :live_component

  def handle_event("send_contract", params, socket) do
    job_application = socket.assigns.job_application
    scope = socket.assigns.scope

    with {:ok, job_offer} <- create_offer(scope, job_application, params),
         {:ok, pdf_binary, filename} <- generate_contract_pdf(job_offer, job_application),
         {:ok, _} <- upload_and_attach_contract(
           scope, job_offer, job_application, pdf_binary, filename
         ) do
      {:noreply,
       socket
       |> put_flash(:info, "Contract sent successfully")
       |> push_navigate(to: ~p"/contracts")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp upload_and_attach_contract(scope, job_offer, job_application, pdf_binary, filename) do
    upload_id = Ecto.UUID.generate()

    with :ok <- Documents.Storage.upload_file(upload_id, pdf_binary, "application/pdf"),
         {:ok, message} <- Chat.create_message_with_media(
           scope,
           scope.user,
           job_application,
           %{
             "content" => "Job offer contract",
             "media_data" => %{
               "file_name" => filename,
               "type" => "application/pdf",
               "status" => :uploaded,
               "upload_id" => upload_id
             }
           }
         ) do
      # Associate message with job offer for easy retrieval
      JobOffers.update_job_offer(scope, job_offer, message, %{
        contract_generated_at: DateTime.utc_now()
      })
    end
  end
end
```

## Considerations

### LibreOffice Installation

**Production servers** need LibreOffice installed:

```bash
# Ubuntu/Debian
apt-get install -y libreoffice-writer libreoffice-calc --no-install-recommends

# Alpine (Docker)
apk add libreoffice
```

**Docker Dockerfile**:

```dockerfile
FROM elixir:1.18-alpine

RUN apk add --no-cache \
    libreoffice \
    ttf-liberation \
    && rm -rf /var/cache/apk/*
```

### Performance Optimization

- **Cache default templates** in application env to avoid repeated S3 downloads
- **Background processing** via Oban for large batches
- **Temp file cleanup** to prevent disk space issues:
  ```elixir
  on_exit(fn ->
    File.rm_rf!(extract_dir)
    File.rm!(docx_path)
    File.rm!(pdf_path)
  end)
  ```

### Security

- **Validate template paths** to prevent directory traversal
- **Sanitize variable values** to prevent XML injection:
  ```elixir
  defp sanitize_value(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
  ```
- **Limit template size** to prevent DoS attacks

### Idempotency

Prevent duplicate contract generation:

```elixir
defp create_and_send_offer(scope, job_application, params) do
  # Check if contract already generated
  if contract_already_exists?(job_application) do
    {:error, :contract_already_generated}
  else
    # Use Ecto.Multi for atomicity
    Multi.new()
    |> Multi.insert(:offer, offer_changeset(params))
    |> Multi.run(:contract, fn _repo, %{offer: offer} ->
      generate_contract_pdf(offer, job_application)
    end)
    |> Multi.run(:upload, fn _repo, %{contract: {pdf_binary, filename}} ->
      upload_and_attach_contract(scope, job_offer, job_application, pdf_binary, filename)
    end)
    |> Repo.transaction()
  end
end

defp contract_already_exists?(job_application) do
  job_application.job_offer &&
    not is_nil(job_application.job_offer.contract_generated_at)
end
```

### When NOT to Use This Pattern

- **Complex layouts**: LibreOffice conversion has limitations - use LaTeX or HTML→PDF (wkhtmltopdf, Puppeteer) for pixel-perfect layouts
- **High throughput**: LibreOffice process spawning is slow - consider Gotenberg (microservice) or PDF libraries (pdf_generator)
- **Real-time generation**: LibreOffice takes 1-5 seconds per conversion - not suitable for synchronous requests

## Example Usage

From the BemedaPersonal negotiation feature:

```elixir
# In OfferDetailsFormComponent
def handle_event("send_contract", %{"job_offer" => params}, socket) do
  job_application = socket.assigns.job_application
  scope = socket.assigns.scope

  # Auto-populate variables from job application data
  variables = JobOffers.auto_populate_variables(job_application)

  # Create offer with variables
  full_params = Map.merge(params, %{
    "job_application_id" => job_application.id,
    "variables" => variables
  })

  with {:ok, job_offer} <- JobOffers.create_job_offer(scope, full_params),
       {:ok, pdf_binary, filename} <- generate_contract_pdf(job_offer, job_application),
       {:ok, _} <- upload_and_attach_contract(
         scope, job_offer, job_application, pdf_binary, filename
       ) do
    # Transition job application state
    JobApplications.update_status(job_application, :offer_extended)

    {:noreply,
     socket
     |> put_flash(:info, "Contract sent to #{applicant_name}")
     |> push_navigate(to: ~p"/contracts")}
  end
end
```

## Related Recipes

- [Phoenix File Upload Patterns](phoenix-file-upload-patterns.md) - For handling DOCX template uploads
- [Background Job Patterns with Oban](oban-background-jobs.md) - For asynchronous PDF generation
