-- CreateEnum
CREATE TYPE "ProvisionAction" AS ENUM ('CREATE', 'UPDATE', 'LOCK', 'UNLOCK', 'DELETE');

-- CreateEnum
CREATE TYPE "ProvisionStatus" AS ENUM ('PENDING', 'DONE', 'FAILED');

-- AlterTable
ALTER TABLE "servers" ADD COLUMN     "agentLastSeen" TIMESTAMP(3),
ADD COLUMN     "agentToken" TEXT,
ADD COLUMN     "agentUserCount" INTEGER,
ADD COLUMN     "agentVersion" TEXT;

-- CreateTable
CREATE TABLE "provision_tasks" (
    "id" TEXT NOT NULL,
    "serverId" TEXT NOT NULL,
    "userId" TEXT,
    "username" TEXT NOT NULL,
    "action" "ProvisionAction" NOT NULL,
    "passwordHash" TEXT,
    "expiresAt" TIMESTAMP(3),
    "connectionLimit" INTEGER,
    "status" "ProvisionStatus" NOT NULL DEFAULT 'PENDING',
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "lastError" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "processedAt" TIMESTAMP(3),

    CONSTRAINT "provision_tasks_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "provision_tasks_serverId_status_createdAt_idx" ON "provision_tasks"("serverId", "status", "createdAt");

-- CreateIndex
CREATE INDEX "provision_tasks_username_idx" ON "provision_tasks"("username");

-- CreateIndex
CREATE UNIQUE INDEX "servers_agentToken_key" ON "servers"("agentToken");

-- AddForeignKey
ALTER TABLE "provision_tasks" ADD CONSTRAINT "provision_tasks_serverId_fkey" FOREIGN KEY ("serverId") REFERENCES "servers"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "provision_tasks" ADD CONSTRAINT "provision_tasks_userId_fkey" FOREIGN KEY ("userId") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;

