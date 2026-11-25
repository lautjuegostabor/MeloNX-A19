using System.Reflection;
using System.Runtime.CompilerServices;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;

const BindingFlags Fields = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
Assembly backend = typeof(VulkanRenderer).Assembly;
Type programType = backend.GetType("Ryujinx.Graphics.Vulkan.ShaderCollection", throwOnError: true);
Type shaderType = backend.GetType("Ryujinx.Graphics.Vulkan.Shader", throwOnError: true);

// The fixture exercises the actual readiness methods using shader modules with
// controlled completion and no Vulkan device. Pipeline creation belongs to the
// renderer on the device and is outside this fixture.
object shader = RuntimeHelpers.GetUninitializedObject(shaderType);
var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
Set(shader, "CompileTask", completion.Task);
Set(shader, "_stage", ShaderStageFlags.ComputeBit);
IProgram pending = CreateProgram(shader);
Expect(pending.CheckProgramLink(false) == ProgramLinkStatus.Incomplete, "Pending shader was reported ready.");

Task<ProgramLinkStatus> waiter = Task.Run(() => pending.CheckProgramLink(true));
Expect(!waiter.IsCompleted, "Link returned before shader completion.");
Set(shader, "_module", new ShaderModule(1));
Set(shader, "_compileStatus", (int)ProgramLinkStatus.Success);
completion.SetResult();
Expect(await waiter.WaitAsync(TimeSpan.FromSeconds(5)) == ProgramLinkStatus.Success, "Successful shader could not link.");
var stages = (PipelineShaderStageCreateInfo[])programType.GetMethod("GetInfos").Invoke(pending, null);
Expect(stages.Length == 1 && stages[0].Module.Handle == 1, "First use did not receive the completed module.");

object failedShader = RuntimeHelpers.GetUninitializedObject(shaderType);
Set(failedShader, "CompileTask", Task.CompletedTask);
Set(failedShader, "_compileStatus", (int)ProgramLinkStatus.Failure);
IProgram failed = CreateProgram(failedShader);
Expect(failed.CheckProgramLink(false) == ProgramLinkStatus.Failure, "Shader failure was treated as ready.");
Expect(failed.CheckProgramLink(true) == ProgramLinkStatus.Failure, "Shader failure was lost on retry.");
stages = (PipelineShaderStageCreateInfo[])programType.GetMethod("GetInfos").Invoke(failed, null);
Expect(stages.Length == 1 && stages[0].Module.Handle == 0, "Failed module was published to the renderer.");
Console.WriteLine("PASS Apple10 program readiness, completed stages and failure propagation");

Type framebufferType = backend.GetType("Ryujinx.Graphics.Vulkan.FramebufferParams", throwOnError: true);
MethodInfo matchesAttachments = framebufferType.GetMethod("HasSameLiveAttachments");
Type viewType = backend.GetType("Ryujinx.Graphics.Vulkan.TextureView", throwOnError: true);
ITexture color = CreateLiveView();
ITexture otherColor = CreateLiveView();
ITexture depth = CreateLiveView();
object framebuffer = RuntimeHelpers.GetUninitializedObject(framebufferType);

Array colors = Array.CreateInstance(viewType, 3);
colors.SetValue(color, 0);
colors.SetValue(otherColor, 2);
Set(framebuffer, "_totalCount", colors.Length);
Set(framebuffer, "_colorsCanonical", colors);
Set(framebuffer, "_depthStencil", depth);

var matches = matchesAttachments.CreateDelegate<MatchAttachments>(framebuffer);
Expect(matches([color, null, otherColor], depth), "Identical live attachments were rejected.");
Expect(!matches([otherColor, null, color], depth), "Reordered attachments were treated as identical.");
Expect(!matches([color, otherColor, otherColor], depth), "New binding in empty slot was missed.");
Expect(!matches([color, null], depth), "A changed color attachment count was missed.");
Expect(!matches([color, null, otherColor], CreateLiveView()), "A replaced depth view was missed.");
Expect(!matches([color, null, otherColor], null), "An unbound depth view was missed.");
Set(otherColor, "_isValid", 0);
Expect(!matches([color, null, otherColor], depth), "Disposed color view was accepted.");
Set(otherColor, "_isValid", 1);
Set(depth, "_isValid", 0);
Expect(!matches([color, null, otherColor], depth), "Disposed depth view was accepted.");

Type flushReason = backend.GetType("Ryujinx.Graphics.Vulkan.CommandFlushReason", throwOnError: true);
Expect(Enum.GetValues(flushReason).Length ==
    Ryujinx.Common.A19Probe.Count - Ryujinx.Common.A19Probe.FirstVulkanFlushReason,
    "Flush reason count does not match the counter layout.");
Console.WriteLine("PASS Apple10 attachment identity, validity and flush counter layout");

ITexture CreateLiveView()
{
    object view = RuntimeHelpers.GetUninitializedObject(viewType);
    Set(view, "_isValid", 1);
    return (ITexture)view;
}

IProgram CreateProgram(object shaderModule)
{
    object program = RuntimeHelpers.GetUninitializedObject(programType);
    Array shaders = Array.CreateInstance(shaderType, 1);
    shaders.SetValue(shaderModule, 0);
    Set(program, "_shaders", shaders);
    Set(program, "_infos", new PipelineShaderStageCreateInfo[1]);
    Set(program, "_initializeLock", new object());
    Set(program, "_createPipelineOnFirstUse", true);
    return (IProgram)program;
}

static void Set(object instance, string field, object value) =>
    instance.GetType().GetField(field, Fields).SetValue(instance, value);

static void Expect(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

internal delegate bool MatchAttachments(ReadOnlySpan<ITexture> colors, ITexture depthStencil);
