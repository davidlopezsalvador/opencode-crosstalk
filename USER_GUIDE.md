# 🤖 User Guide: Coordinating your AI Team with Cross-Talk

This guide is for users who want to utilize the system without writing a single line of code. In this workflow, you are the **Director**, one AI is the **Leader**, and the others are the **Advisors**.

## 🏁 Step 1: Project Preparation
1. **Copy the `opencode-cross-talk` folder** into your workspace or project directory.
2. **Open that project** in OpenCode Desktop or CLI.
3. **Open several chat sessions** (for example, three different windows).
   - One will be your **Leader**.
   - The others will be your **Advisors**.

## 👑 Step 2: Activating the Leader
Go to the chat you have chosen as the **Leader** and tell it the following (you can copy and paste):

> "Activate the Cross-Talk protocol. Read the `README.md` and `CROSS_TALK.md` files to understand how to communicate with other sessions. Your first task is to discover all available sessions in this project, list them for me, and ask which advisors I want to include in the team (or if I want to use all of them). Do not assign any tasks until I confirm the team."

**What will the AI do?**
The AI will read the documentation, use the `sessions` command to find other chats, and then present you with a list of available "candidates". It will then wait for your instructions to form the team.

## 🎯 Step 3: Launching the Task
Now, simply tell the **Leader** what you want to achieve. You don't need to explain *how* to do it, just *what* you want.

**Examples of instructions for the Leader:**
- "I need to analyze this code. Coordinate with the other available agents: distribute the analysis by module and provide me with a consolidated final report."
- "We are going to write a technical document. You design the structure and ask the advisors to write each section according to your plan."

---

## ⚙️ What happens "behind the scenes"? (For your peace of mind)

You won't see any code, but the **Leader** will do the following autonomously:
1. **Finds its teammates:** It uses the `sessions` command to find the IDs of the other chats.
2. **Assigns tasks:** It sends direct messages to the Advisors with clear instructions.
3. **Tracks progress:** It waits for confirmations (ACK) and, if an Advisor goes silent, it will send a "nudge" (`sigue`) to wake them up.
4. **Synthesizes the result:** It collects all responses and presents the final result to you.

## 💡 Tips for better results
- **Give the Leader a role:** You can tell it: *"Act as a Senior Software Architect and coordinate the team"*.
- **Supervise the Whiteboard:** If the project uses a `whiteboard/` folder, you can check the `.md` files to see how the Leader and Advisors are organizing the task in real-time.
- **Intervene if necessary:** If you see the Leader making a mistake, simply tell it: *"Correct the instruction you gave to Advisor B; the approach should be X and not Y"*.
